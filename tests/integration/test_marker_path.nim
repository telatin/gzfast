## Milestone 8 public ordinary-gzip marker path tests.

import std/[options, os, strutils, unittest]
import gzfast
import gzfast/private/zlib_api
import ../helpers/deflate_bits

proc appendLe32(output: var string; value: uint32) =
  for shift in [0, 8, 16, 24]:
    output.add(char((value shr shift) and 0xFF))

proc gzipMember(raw: seq[byte]; plain: string): string =
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  for value in raw: result.add(char(value))
  result.appendLe32(crc32(plain))
  result.appendLe32(uint32(plain.len))

proc buildParallelMarkerFixture(): tuple[gzip, plain: string] =
  var writer: TestBitWriter
  # Candidate 0.
  writer.addMinimalDynamicHeader(final = false)
  writer.addBits(0, 1) # dynamic EOB
  writer.addFixedBlockHeader(final = false)
  for _ in 0 ..< 2000: writer.addFixedSymbol(ord('A'))
  writer.addFixedSymbol(256)
  # Candidate 1, over one compressed grid later.
  writer.addMinimalDynamicHeader(final = false)
  writer.addBits(0, 1)
  writer.addFixedBlockHeader(final = false)
  for _ in 0 ..< 2000: writer.addFixedSymbol(ord('A'))
  writer.addFixedSymbol(256)
  # Candidate 2. The final fixed block immediately refers to predecessor.
  writer.addMinimalDynamicHeader(final = false)
  writer.addBits(0, 1)
  writer.addFixedBlockHeader(final = true)
  writer.addFixedSymbol(285) # length 258
  writer.addFixedDistance(0) # distance 1
  writer.addFixedSymbol(256)
  result.plain = repeat('A', 4258)
  result.gzip = gzipMember(writer.bytes(), result.plain)

proc readEverything(path: string; config: GzFastConfig):
    tuple[data: string, report: DecodeReport] =
  let input = initGzFastDecoder(config).open(path)
  defer: input.close()
  var buffer = newString(317)
  while true:
    let count = input.readData(addr buffer[0], buffer.len)
    if count == 0: break
    result.data.add(buffer[0 ..< count])
  result.report = input.finish()

proc markerConfig(threads: int): GzFastConfig =
  result = defaultGzFastConfig()
  result.threads = threads
  result.enableMarkerPath = true
  result.compressedGridSize = 1024

suite "ordinary gzip marker path":
  test "marker path is opt-in for ordinary gzip":
    let fixture = buildParallelMarkerFixture()
    let path = getTempDir() / "gzfast_marker_default_off.gz"
    writeFile(path, fixture.gzip)
    defer: removeFile(path)
    var config = defaultGzFastConfig()
    config.threads = 4
    config.compressedGridSize = 1024
    let decoded = readEverything(path, config)
    check decoded.data == fixture.plain
    check decoded.report.pathsUsed == {dpSequential}
    check decoded.report.crcVerified

  test "rolling marker jobs resolve predecessor matches in order":
    let fixture = buildParallelMarkerFixture()
    let path = getTempDir() / "gzfast_marker_parallel.gz"
    writeFile(path, fixture.gzip)
    defer: removeFile(path)
    var config = markerConfig(4)
    config.inputPageSize = 4096
    config.inFlightChunks = 4
    for workers in [2, 3, 4]:
      config.threads = workers
      let parallel = readEverything(path, config)
      check parallel.data == fixture.plain
      check parallel.report.pathsUsed == {dpMarkerWindow}
      check parallel.report.memberCount == 1
      check parallel.report.crcVerified
      check parallel.report.peakWorkers >= 2

    config.threads = 1
    let sequential = readEverything(path, config)
    check sequential.data == fixture.plain
    check sequential.report.pathsUsed == {dpSequential}

  test "finish before EOF resolves and verifies the full marker chain":
    let fixture = buildParallelMarkerFixture()
    let path = getTempDir() / "gzfast_marker_finish.gz"
    writeFile(path, fixture.gzip)
    defer: removeFile(path)
    var config = markerConfig(3)
    let input = initGzFastDecoder(config).open(path)
    var byte: char
    check input.readData(addr byte, 1) == 1
    let report = input.finish()
    input.close()
    check report.decompressedBytes == uint64(fixture.plain.len)
    check report.memberCount == 1
    check report.crcVerified

  test "valid dynamic header bytes inside stored payload fall back safely":
    var fake: TestBitWriter
    fake.addMinimalDynamicHeader(final = false)
    fake.addBits(0, 1)
    let payloadBytes = fake.bytes()
    var payload = repeat('\0', 1300)
    for value in payloadBytes: payload.add(char(value))
    payload.add(repeat('\0', 1300))
    var raw: TestBitWriter
    raw.addBits(1, 1); raw.addBits(0, 2); raw.alignByte()
    raw.addBits(uint32(payload.len), 16)
    raw.addBits(uint32(not uint16(payload.len)), 16)
    for c in payload: raw.addByte(byte(c))
    let path = getTempDir() / "gzfast_marker_false_candidate.gz"
    writeFile(path, gzipMember(raw.bytes(), payload))
    defer: removeFile(path)
    var config = markerConfig(4)
    let decoded = readEverything(path, config)
    check decoded.data == payload
    check decoded.report.crcVerified
    check dpSequential in decoded.report.pathsUsed

  test "false candidate after real boundary triggers exact bridge":
    var fake: TestBitWriter
    fake.addMinimalDynamicHeader(final = false)
    fake.addBits(0, 1)
    var payload = repeat('\0', 1200)
    for value in fake.bytes(): payload.add(char(value))
    payload.add(repeat('\0', 1200))

    var raw: TestBitWriter
    raw.addMinimalDynamicHeader(final = false)
    raw.addBits(0, 1) # authoritative candidate at payload start
    raw.addBits(0, 1); raw.addBits(0, 2); raw.alignByte()
    raw.addBits(uint32(payload.len), 16)
    raw.addBits(uint32(not uint16(payload.len)), 16)
    for c in payload: raw.addByte(byte(c))
    raw.addFixedBlockHeader(final = true)
    raw.addFixedSymbol(ord('Z'))
    raw.addFixedSymbol(256)
    let plain = payload & "Z"
    let path = getTempDir() / "gzfast_marker_boundary_mismatch.gz"
    writeFile(path, gzipMember(raw.bytes(), plain))
    defer: removeFile(path)
    var config = markerConfig(4)
    let decoded = readEverything(path, config)
    check decoded.data == plain
    check decoded.report.crcVerified
    check dpMarkerWindow in decoded.report.pathsUsed
    check dpSequential in decoded.report.pathsUsed
    check dpMixed in decoded.report.pathsUsed

  test "terminal footer corruption is authoritative":
    let fixture = buildParallelMarkerFixture()
    var corrupt = fixture.gzip
    corrupt[^8] = char(byte(corrupt[^8]) xor 0x80)
    let path = getTempDir() / "gzfast_marker_bad_crc.gz"
    writeFile(path, corrupt)
    defer: removeFile(path)
    var config = markerConfig(4)
    let input = initGzFastDecoder(config).open(path)
    defer: input.close()
    var buffer = newString(512)
    try:
      while input.readData(addr buffer[0], buffer.len) != 0: discard
      check false
    except GzFastError as error:
      check error.kind == geChecksumMismatch

  test "early close cancels marker workers":
    let fixture = buildParallelMarkerFixture()
    let path = getTempDir() / "gzfast_marker_close.gz"
    writeFile(path, fixture.gzip)
    defer: removeFile(path)
    var config = markerConfig(4)
    for _ in 0 ..< 20:
      let input = initGzFastDecoder(config).open(path)
      var byte: char
      discard input.readData(addr byte, 1)
      input.close()

  test "global output limit rejects before excess marker output":
    let fixture = buildParallelMarkerFixture()
    let path = getTempDir() / "gzfast_marker_limit.gz"
    writeFile(path, fixture.gzip)
    defer: removeFile(path)
    var config = markerConfig(4)
    config.outputLimit = some(3000'u64)
    let input = initGzFastDecoder(config).open(path)
    defer: input.close()
    var output: string
    var buffer = newString(211)
    try:
      while true:
        let count = input.readData(addr buffer[0], buffer.len)
        if count == 0: break
        output.add(buffer[0 ..< count])
      check false
    except GzFastError as error:
      check error.kind == geOutputLimit
      check output.len <= 3000

  test "output limit spans the marker to sequential member boundary":
    # Member 0 decodes through the marker path; member 1 through the
    # sequential fallback opened after the verified footer. The fallback
    # limit must be reduced by the bytes the marker path already emitted.
    # inFlightChunks = 2 keeps the member-parallel probe span shorter than
    # member 0, so the file is not claimed by the member-parallel path.
    let fixture = buildParallelMarkerFixture()
    var secondRaw: TestBitWriter
    secondRaw.addBits(1, 1)
    secondRaw.addBits(0, 2)
    secondRaw.alignByte()
    let secondPlain = repeat('B', 1000)
    secondRaw.addBits(uint32(secondPlain.len), 16)
    secondRaw.addBits(uint32(not uint16(secondPlain.len)), 16)
    for c in secondPlain:
      secondRaw.addByte(byte(c))
    let combined = fixture.gzip & gzipMember(secondRaw.bytes(), secondPlain)
    let path = getTempDir() / "gzfast_marker_limit_members.gz"
    writeFile(path, combined)
    defer: removeFile(path)
    let fullPlain = fixture.plain & secondPlain

    var config = markerConfig(4)
    config.inFlightChunks = 2
    config.outputLimit = some(uint64(fixture.plain.len + 500))
    let input = initGzFastDecoder(config).open(path)
    defer: input.close()
    var output: string
    var buffer = newString(211)
    try:
      while true:
        let count = input.readData(addr buffer[0], buffer.len)
        if count == 0: break
        output.add(buffer[0 ..< count])
      check false
    except GzFastError as error:
      check error.kind == geOutputLimit
      check output.len == fixture.plain.len + 500
      check output == fullPlain[0 ..< output.len]

    var exactConfig = markerConfig(4)
    exactConfig.inFlightChunks = 2
    exactConfig.outputLimit = some(uint64(fullPlain.len))
    let exact = readEverything(path, exactConfig)
    check exact.data == fullPlain
    check exact.report.crcVerified
    check dpMarkerWindow in exact.report.pathsUsed
    check dpSequential in exact.report.pathsUsed

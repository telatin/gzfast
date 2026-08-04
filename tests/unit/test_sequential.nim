## Milestone 2 acceptance tests: the authoritative sequential decoder.

import std/[unittest, streams, options]
import gzfast/config, gzfast/errors, gzfast/report
import gzfast/paths/sequential
import gzfast/private/zlib_api
import ../helpers/fixtures

proc decodeAll(path: string; config = defaultGzFastConfig();
               readSize = 65536): tuple[crc: uint32, total: uint64,
                                         report: DecodeReport] =
  var dec = openSequentialDecoder(path, config)
  defer: dec.close()
  var buf = newString(readSize)
  var crc = 0'u32
  var total = 0'u64
  while true:
    let n = dec.readData(addr buf[0], buf.len)
    if n == 0:
      break
    crc = gzCrc32(crc, cast[ptr byte](addr buf[0]), csize_t(n))
    total += n.uint64
  (crc, total, dec.report())

suite "sequential decoder: valid corpus":
  for f in fixtures():
    test "decodes " & f.name:
      let (crc, total, report) = decodeAll(fixturePath(f.name))
      check total == f.length
      check crc == f.crc32
      check report.memberCount == uint64(f.members)
      check report.crcVerified
      check report.compressedBytes > 0'u64

  test "read sizes from 1 byte up give identical results":
    let f = fixtureByName("small_text.gz")
    var prevCrc = 0'u32
    for size in [1, 2, 3, 7, 64, 4097, 1 shl 20]:
      let (crc, total, _) = decodeAll(fixturePath(f.name), readSize = size)
      check total == f.length
      if prevCrc != 0:
        check crc == prevCrc
      prevCrc = crc

  test "decoding from a non-positional stream works":
    let data = readFixture("small_text.gz")
    let s = newStringStream(data)
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(100)
    var crc = 0'u32
    var total = 0'u64
    while true:
      let n = dec.readData(addr buf[0], buf.len)
      if n == 0: break
      crc = gzCrc32(crc, cast[ptr byte](addr buf[0]), csize_t(n))
      total += n.uint64
    check total == 2880'u64
    check crc == fixtureByName("small_text.gz").crc32

suite "sequential decoder: corruption handling":
  test "truncation at every byte of small fixtures always errors":
    for name in ["empty.gz", "one_byte.gz", "small_text.gz"]:
      let data = readFixture(name)
      for cut in 0 ..< data.len:
        let s = newStringStream(data[0 ..< cut])
        var dec = openSequentialDecoder(s, defaultGzFastConfig())
        var buf = newString(256)
        var raised = false
        try:
          while dec.readData(addr buf[0], buf.len) != 0:
            discard
        except GzFastError as e:
          raised = true
          check e.kind in {geTruncatedInput, geInvalidHeader,
                           geInvalidDeflate, geChecksumMismatch,
                           geSizeMismatch}
        dec.close()
        check raised

  test "corrupt CRC32 is detected":
    var data = toBytes(readFixture("small_text.gz"))
    data[^8] = data[^8] xor 0xFF
    let s = newStringStream(toString(data))
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(4096)
    expect GzFastError:
      while dec.readData(addr buf[0], buf.len) != 0:
        discard

  test "corrupt ISIZE is detected":
    var data = toBytes(readFixture("small_text.gz"))
    data[^4] = data[^4] xor 0xFF
    let s = newStringStream(toString(data))
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(4096)
    try:
      while dec.readData(addr buf[0], buf.len) != 0:
        discard
      check false
    except GzFastError as e:
      check e.kind == geSizeMismatch

  test "bad magic is rejected with offset":
    var data = toBytes(readFixture("small_text.gz"))
    data[0] = 0x1E
    let s = newStringStream(toString(data))
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(16)
    try:
      discard dec.readData(addr buf[0], buf.len)
      check false
    except GzFastError as e:
      check e.kind == geInvalidHeader
      check e.compressedOffset == 0'u64

  test "trailing junk after final member is rejected":
    var data = toBytes(readFixture("small_text.gz"))
    data.add([0x00'u8, 0x11, 0x22])
    let s = newStringStream(toString(data))
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(4096)
    try:
      while dec.readData(addr buf[0], buf.len) != 0:
        discard
      check false
    except GzFastError as e:
      check e.kind == geInvalidHeader

  test "corrupt deflate bits are detected":
    var data = toBytes(readFixture("small_text.gz"))
    for i in 10 ..< 16:
      data[i] = data[i] xor 0xFF
    let s = newStringStream(toString(data))
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(4096)
    try:
      while dec.readData(addr buf[0], buf.len) != 0:
        discard
      check false
    except GzFastError as e:
      check e.kind in {geInvalidDeflate, geChecksumMismatch, geSizeMismatch}

  test "empty input is truncated, not invalid":
    let s = newStringStream("")
    var dec = openSequentialDecoder(s, defaultGzFastConfig())
    defer: dec.close()
    var buf = newString(4)
    try:
      discard dec.readData(addr buf[0], buf.len)
      check false
    except GzFastError as e:
      check e.kind == geTruncatedInput

suite "sequential decoder: limits and bounded memory":
  test "outputLimit delivers exactly the limit then raises":
    var config = defaultGzFastConfig()
    config.outputLimit = some(1000'u64)
    var dec = openSequentialDecoder(fixturePath("small_text.gz"), config)
    defer: dec.close()
    var buf = newString(600)
    check dec.readData(addr buf[0], 600) == 600
    check dec.readData(addr buf[0], 600) == 400
    try:
      discard dec.readData(addr buf[0], 600)
      check false
    except GzFastError as e:
      check e.kind == geOutputLimit

  test "outputLimit exactly equal to decoded size succeeds":
    var config = defaultGzFastConfig()
    config.outputLimit = some(2880'u64)
    let (_, total, report) = decodeAll(fixturePath("small_text.gz"), config)
    check total == 2880'u64
    check report.crcVerified

  test "tiny pages decode a larger file correctly":
    var config = defaultGzFastConfig()
    config.inputPageSize = 4096
    config.decodedChunkSize = 4096
    let (crc, total, _) = decodeAll(fixturePath("repetitive.gz"), config)
    check total == 589824'u64
    check crc == fixtureByName("repetitive.gz").crc32

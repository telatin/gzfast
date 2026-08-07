## Milestone 3 acceptance tests: public API surface.

import std/[unittest, streams, os]
import gzfast
import gzfast/private/zlib_api
import ../helpers/fixtures

suite "public API":
  test "config validation":
    var c = defaultGzFastConfig()
    c.validate()
    c.threads = -1
    expect GzFastConfigError:
      c.validate()
    c = defaultGzFastConfig()
    c.decodedChunkSize = 10
    expect GzFastConfigError:
      c.validate()

  test "openGzFast streams a fixture":
    let f = fixtureByName("fastq.gz")
    let input = openGzFast(fixturePath(f.name), threads = 4)
    var total = 0'u64
    var lineCount = 0
    for line in input.lines:
      inc lineCount
      total += line.len.uint64 + 1
    check lineCount == 8000
    check total == f.length
    let report = input.finish()
    input.close()
    check report.crcVerified
    check report.decompressedBytes == f.length
    check report.memberCount == 1'u64

  test "finish before EOF verifies the whole stream":
    let f = fixtureByName("fastq.gz")
    let input = openGzFast(fixturePath(f.name))
    var buf = newString(100)
    check input.readData(addr buf[0], 100) == 100
    let report = input.finish()
    check report.crcVerified
    check report.decompressedBytes == f.length
    input.close()

  test "reading after finish returns EOF":
    let input = openGzFast(fixturePath("one_byte.gz"))
    discard input.finish()
    var buf = newString(8)
    check input.readData(addr buf[0], 8) == 0
    check input.atEnd()
    input.close()

  test "peekDecoded and consumeDecoded stream borrowed sequential spans":
    let reference = block:
      let input = openGzFast(fixturePath("small_text.gz"), threads = 1)
      defer: input.close()
      input.readAll()

    let input = openGzFast(fixturePath("small_text.gz"), threads = 1)
    var actual = newStringOfCap(reference.len)
    while true:
      let span = input.peekDecoded()
      if span.len == 0:
        break
      check span.data != nil
      let take = min(span.len, 17)
      for i in 0..<take:
        actual.add char(span.data[i])
      input.consumeDecoded(take)
    let report = input.finish()
    input.close()
    check actual == reference
    check report.crcVerified
    check report.decompressedBytes == uint64(reference.len)

  test "peekDecoded works on parallel-backed readers":
    let reference = block:
      let input = openGzFast(fixturePath("bgzf.gz"), threads = 1)
      defer: input.close()
      input.readAll()

    let input = openGzFast(fixturePath("bgzf.gz"), threads = 4)
    var actual = newStringOfCap(reference.len)
    while true:
      let span = input.peekDecoded()
      if span.len == 0:
        break
      for i in 0..<span.len:
        actual.add char(span.data[i])
      input.consumeDecoded(span.len)
    let report = input.finish()
    input.close()
    check actual == reference
    check report.crcVerified
    check dpBgzf in report.pathsUsed

  test "consumeDecoded rejects counts beyond the current span":
    let input = openGzFast(fixturePath("small_text.gz"), threads = 1)
    let span = input.peekDecoded()
    check span.len > 0
    expect ValueError:
      input.consumeDecoded(span.len + 1)
    input.close()

  test "cancel stops reading":
    let input = openGzFast(fixturePath("repetitive.gz"))
    var buf = newString(16)
    discard input.readData(addr buf[0], 16)
    input.cancel()
    expect GzFastError:
      discard input.readData(addr buf[0], 16)
    input.close()

  test "decodeTo and reader produce identical output and reports":
    let f = fixtureByName("repetitive.gz")
    let reader = openGzFast(fixturePath(f.name))
    var viaReader = newString(f.length)
    var off = 0
    while off < viaReader.len:
      let n = reader.readData(addr viaReader[off],
                              min(65536, viaReader.len - off))
      if n == 0: break
      off += n
    let r1 = reader.finish()
    reader.close()

    let mem = newStringStream()
    let decoder = initGzFastDecoder(2)
    let r2 = decoder.decodeTo(fixturePath(f.name), mem)
    check r2.decompressedBytes == r1.decompressedBytes
    check r2.memberCount == r1.memberCount
    check r2.crcVerified == r1.crcVerified
    mem.setPosition(0)
    check mem.readAll() == viaReader[0 ..< off]

  test "decompressFile round-trip":
    let f = fixtureByName("small_text.gz")
    let tmp = getTempDir() / "gzfast_test_decompress.out"
    defer: removeFile(tmp)
    let report = decompressFile(fixturePath(f.name), tmp)
    check report.crcVerified
    let content = readFile(tmp)
    check content.len == int(f.length)
    check crc32(content) == f.crc32

  test "openGzFastSequential on a memory stream":
    let f = fixtureByName("concat_3.gz")
    let s = newStringStream(readFixture(f.name))
    let input = openGzFastSequential(s)
    var total = 0'u64
    var buf = newString(1000)
    while true:
      let n = input.readData(addr buf[0], buf.len)
      if n == 0: break
      total += n.uint64
    let report = input.finish()
    input.close()
    check total == f.length
    check report.memberCount == 3'u64

  test "missing input file raises geInputIo":
    try:
      discard openGzFast("/nonexistent/definitely-not-here.gz")
      check false
    except GzFastError as e:
      check e.kind == geInputIo

  test "seeking is unsupported and does not restart decoding":
    let input = openGzFast(fixturePath("small_text.gz"))
    var buf = newString(16)
    discard input.readData(addr buf[0], 16)
    expect IOError:
      input.setPosition(0)
    # stream still works afterwards
    check input.readData(addr buf[0], 16) > 0
    input.close()

  test "stats snapshot reports progress":
    let input = openGzFast(fixturePath("small_text.gz"))
    var buf = newString(100)
    discard input.readData(addr buf[0], 100)
    let s = input.stats()
    check s.decompressedBytes >= 100'u64
    check not s.finished
    discard input.finish()
    check input.stats().finished
    input.close()

  test "BGZF path emits verified blocks in order":
    let fixture = fixtureByName("bgzf.gz")
    let input = openGzFast(fixturePath(fixture.name), threads = 4)
    var buf = newString(4096)
    var total = 0'u64
    var crc = 0'u32
    while true:
      let n = input.readData(addr buf[0], buf.len)
      if n == 0: break
      crc = gzCrc32(crc, cast[ptr byte](addr buf[0]), csize_t(n))
      total += uint64(n)
    let report = input.finish()
    input.close()
    check total == fixture.length
    check crc == fixture.crc32
    check report.memberCount == uint64(fixture.members)
    check report.pathsUsed == {dpBgzf}
    check report.crcVerified
    check report.peakWorkers >= 2

  test "ordinary concatenated members use parallel member path":
    let fixture = fixtureByName("concat_3.gz")
    let input = openGzFast(fixturePath(fixture.name), threads = 3)
    var buf = newString(777)
    var total = 0'u64
    var crc = 0'u32
    while true:
      let n = input.readData(addr buf[0], buf.len)
      if n == 0: break
      crc = gzCrc32(crc, cast[ptr byte](addr buf[0]), csize_t(n))
      total += uint64(n)
    let report = input.finish()
    input.close()
    check total == fixture.length
    check crc == fixture.crc32
    check report.memberCount == 3
    check report.pathsUsed == {dpMultiMember}
    check report.crcVerified

  test "threads one forces authoritative sequential path":
    let input = openGzFast(fixturePath("bgzf.gz"), threads = 1)
    let report = input.finish()
    input.close()
    check report.pathsUsed == {dpSequential}

  test "broken BGZF chain falls back at uncommitted boundary":
    let path = getTempDir() / "gzfast_mixed_bgzf.gz"
    writeFile(path, readFixture("bgzf.gz") & readFixture("small_text.gz"))
    defer: removeFile(path)
    let input = openGzFast(path, threads = 4)
    var buf = newString(4096)
    var total = 0'u64
    var crc = 0'u32
    var actual = newStringOfCap(110000)
    while true:
      let n = input.readData(addr buf[0], buf.len)
      if n == 0: break
      crc = gzCrc32(crc, cast[ptr byte](addr buf[0]), csize_t(n))
      total += uint64(n)
      actual.add buf[0 ..< n]
    let report = input.finish()
    input.close()
    let bgzf = fixtureByName("bgzf.gz")
    let text = fixtureByName("small_text.gz")
    check total == bgzf.length + text.length
    # CRC of concatenated output, computed independently through direct bytes.
    let bgzfDecoded = block:
      let source = openGzFast(fixturePath("bgzf.gz"), threads = 1)
      defer: source.close()
      source.readAll()
    let textDecoded = block:
      let source = openGzFast(fixturePath("small_text.gz"), threads = 1)
      defer: source.close()
      source.readAll()
    check bgzfDecoded.len == int(bgzf.length)
    check textDecoded.len == int(text.length)
    check crc == crc32(actual)
    check actual == bgzfDecoded & textDecoded
    check report.memberCount == uint64(bgzf.members + text.members)
    check dpBgzf in report.pathsUsed
    check dpSequential in report.pathsUsed
    check dpMixed in report.pathsUsed
    check report.crcVerified

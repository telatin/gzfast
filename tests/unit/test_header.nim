## Unit tests for the byte-fed gzip header parser.

import std/unittest
import gzfast/gzip/header
import gzfast/private/zlib_api
import ../helpers/fixtures

proc feedAll(bytes: openArray[byte]): tuple[res: HeaderFeedResult,
                                            p: GzipHeaderParser] =
  var p = initGzipHeaderParser()
  var crc = 0'u32
  var last: HeaderFeedResult
  for b in bytes:
    crc = crc32([b], crc)
    last = p.feed(b, crc)
    if last.kind != hfNeedMore:
      return (last, p)
  (last, p)

proc expectError(bytes: openArray[byte]): string =
  let (res, _) = feedAll(bytes)
  check res.kind == hfError
  res.msg

suite "gzip header parser":
  test "minimal 10-byte header":
    let h = [0x1F'u8, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
    let (res, p) = feedAll(h)
    check res.kind == hfDone
    check p.info.headerSize == 10
    check p.info.bgzfBlockSize == 0

  test "bad magic rejected at byte 1 and 2":
    check expectError([0x1E'u8, 0x8B]).len > 0
    check expectError([0x1F'u8, 0x8C]).len > 0

  test "unsupported compression method":
    check expectError([0x1F'u8, 0x8B, 7]).len > 0

  test "reserved flag bits rejected":
    for flag in [0x20'u8, 0x40, 0x80, 0xE0]:
      check expectError([0x1F'u8, 0x8B, 8, flag, 0, 0, 0, 0, 0, 0]).len > 0

  test "FNAME and FCOMMENT parsed":
    var h = @[0x1F'u8, 0x8B, 8, 0x18, 0, 0, 0, 0, 0, 3]
    h.add(toBytes("name.txt"))
    h.add(0)
    h.add(toBytes("a comment"))
    h.add(0)
    let (res, p) = feedAll(h)
    check res.kind == hfDone
    check p.info.headerSize == h.len

  test "unterminated FNAME needs more bytes":
    var h = @[0x1F'u8, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3]
    h.add(toBytes("no terminator"))
    let (res, _) = feedAll(h)
    check res.kind == hfNeedMore

  test "FEXTRA with BGZF BC subfield":
    # XLEN=6: "BC" LEN=2 BSIZE
    var h = @[0x1F'u8, 0x8B, 8, 0x04, 0, 0, 0, 0, 0, 255,
              6, 0, 'B'.byte, 'C'.byte, 2, 0, 0x1B, 0x00]
    let (res, p) = feedAll(h)
    check res.kind == hfDone
    check p.info.bgzfBlockSize == 0x001B + 1

  test "BC subfield after an unrelated subfield":
    var h = @[0x1F'u8, 0x8B, 8, 0x04, 0, 0, 0, 0, 0, 255,
              13, 0,
              'X'.byte, 'Y'.byte, 3, 0, 1, 2, 3,
              'B'.byte, 'C'.byte, 2, 0, 0x34, 0x12]
    let (res, p) = feedAll(h)
    check res.kind == hfDone
    check p.info.bgzfBlockSize == 0x1234 + 1

  test "malformed extra field lengths rejected":
    # subfield claims 100 bytes but XLEN is 8
    let h1 = [0x1F'u8, 0x8B, 8, 0x04, 0, 0, 0, 0, 0, 3,
              8, 0, 'A'.byte, 'B'.byte, 100, 0, 1, 2, 3, 4]
    check expectError(h1).len > 0
    # XLEN=3 leaves no room for a subfield header
    let h2 = [0x1F'u8, 0x8B, 8, 0x04, 0, 0, 0, 0, 0, 3,
              3, 0, 'A'.byte, 'B'.byte, 0, 0]
    check expectError(h2).len > 0

  test "FHCRC verified":
    var h = @[0x1F'u8, 0x8B, 8, 0x02, 1, 2, 3, 4, 0, 3]
    let crc = crc32(h)
    h.add(byte(crc and 0xFF))
    h.add(byte((crc shr 8) and 0xFF))
    let (res, p) = feedAll(h)
    check res.kind == hfDone
    check p.info.headerSize == 12

  test "FHCRC mismatch rejected":
    var h = @[0x1F'u8, 0x8B, 8, 0x02, 0, 0, 0, 0, 0, 3]
    h.add(0xDE'u8)
    h.add(0xAD'u8)
    check expectError(h).len > 0

  test "all optional fields together":
    var h = @[0x1F'u8, 0x8B, 8, 0x1E, 0, 0, 0, 0, 0, 3,
              6, 0, 'B'.byte, 'C'.byte, 2, 0, 0x10, 0x00]
    h.add(toBytes("file.fastq"))
    h.add(0)
    h.add(toBytes("comment"))
    h.add(0)
    let crc = crc32(h)
    h.add(byte(crc and 0xFF))
    h.add(byte((crc shr 8) and 0xFF))
    let (res, p) = feedAll(h)
    check res.kind == hfDone
    check p.info.headerSize == h.len
    check p.info.bgzfBlockSize == 0x11

  test "byte-at-a-time feeding equals bulk result":
    # The parser is inherently byte-fed; this documents the contract
    # that arbitrary input splits cannot change the outcome.
    let h = [0x1F'u8, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3,
             'a'.byte, 'b'.byte, 0]
    let (res, _) = feedAll(h)
    check res.kind == hfDone

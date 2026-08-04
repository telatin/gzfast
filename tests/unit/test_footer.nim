## Unit tests for the gzip footer parser.

import std/unittest
import gzfast/gzip/footer

suite "gzip footer parser":
  test "parses little-endian CRC32 and ISIZE":
    let f = parseGzipFooter([0x26'u8, 0x39, 0xF4, 0xCB,
                             0x09, 0x00, 0x00, 0x00])
    check f.crc32 == 0xCBF43926'u32
    check f.isize == 9

  test "ISIZE wraps at 2^32":
    let f = parseGzipFooter([0'u8, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
    check f.isize == 0xFFFFFFFF'u32

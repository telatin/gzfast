## Milestone 1 acceptance tests: vendored zlib shim, CRC32, raw inflate.

import std/unittest
import gzfast/private/zlib_api
import ../helpers/fixtures

suite "vendored zlib shim":
  test "zlib version is 1.3.2":
    check $gzZlibVersion() == "1.3.2"

  test "crc32 known vectors":
    check crc32("") == 0x00000000'u32
    check crc32("123456789") == 0xCBF43926'u32
    check crc32("The quick brown fox jumps over the lazy dog") ==
      0x414FA339'u32

  test "crc32 incremental equals one-pass":
    let data = "abcdefghijklmnopqrstuvwxyz0123456789"
    let onePass = crc32(data)
    var inc = crc32("")
    for c in data:
      inc = crc32($c, inc)
    check inc == onePass

  test "crc32_combine equals one-pass for every split point":
    let data = "The quick brown fox jumps over the lazy dog. " &
               "Pack my box with five dozen liquor jugs."
    let whole = crc32(data)
    for split in [0, 1, 7, 20, data.len - 1, data.len]:
      let a = crc32(data[0 ..< split])
      let b = crc32(data[split ..< data.len])
      check gzCrc32Combine(a, b, uint64(data.len - split)) == whole

  test "raw inflate of a fixture":
    let compressed = readFixture("raw_deflate.bin")
    let expected = readFixture("raw_deflate.expected")
    let inflater = gzInflaterCreate()
    check not inflater.isNil
    defer: gzInflaterDestroy(inflater)

    var outBuf = newString(expected.len + 16)
    var inPtr = cast[ptr byte](unsafeAddr compressed[0])
    var inLen = csize_t(compressed.len)
    var outPtr = cast[ptr byte](addr outBuf[0])
    var outLen = csize_t(outBuf.len)
    let ret = gzInflaterStep(inflater, addr inPtr, addr inLen,
                             addr outPtr, addr outLen, gzFinish)
    check ret == gzStreamEnd
    check inLen == 0
    let produced = outBuf.len - int(outLen)
    check produced == expected.len
    check outBuf[0 ..< produced] == expected

  test "raw deflate of a buffer":
    let plain = "The shim can emit raw deflate data without a gzip wrapper."
    let deflater = gzDeflaterCreate(6, gzDefaultStrategy)
    check not deflater.isNil
    defer: gzDeflaterDestroy(deflater)

    var compressedBuf = newString(256)
    var defInPtr = cast[ptr byte](unsafeAddr plain[0])
    var defInLen = csize_t(plain.len)
    var defOutPtr = cast[ptr byte](addr compressedBuf[0])
    var defOutLen = csize_t(compressedBuf.len)
    let defRet = gzDeflaterStep(deflater, addr defInPtr, addr defInLen,
                                addr defOutPtr, addr defOutLen, gzFinish)
    check defRet == gzStreamEnd
    check defInLen == 0
    let compressedLen = compressedBuf.len - int(defOutLen)
    check compressedLen > 0

    let inflater = gzInflaterCreate()
    check not inflater.isNil
    defer: gzInflaterDestroy(inflater)
    var outBuf = newString(plain.len)
    var infInPtr = cast[ptr byte](addr compressedBuf[0])
    var infInLen = csize_t(compressedLen)
    var infOutPtr = cast[ptr byte](addr outBuf[0])
    var infOutLen = csize_t(outBuf.len)
    let infRet = gzInflaterStep(inflater, addr infInPtr, addr infInLen,
                                addr infOutPtr, addr infOutLen, gzFinish)
    check infRet == gzStreamEnd
    check infInLen == 0
    check outBuf == plain

  test "inflater reset and reuse across many decodes":
    let compressed = readFixture("raw_deflate.bin")
    let expected = readFixture("raw_deflate.expected")
    let inflater = gzInflaterCreate()
    defer: gzInflaterDestroy(inflater)
    for i in 0 ..< 25:
      if i > 0:
        check gzInflaterReset(inflater) == gzOk
      var outBuf = newString(expected.len)
      var inPtr = cast[ptr byte](unsafeAddr compressed[0])
      var inLen = csize_t(compressed.len)
      var outPtr = cast[ptr byte](addr outBuf[0])
      var outLen = csize_t(outBuf.len)
      # drip-feed in small output pieces to exercise stepping
      var produced = 0
      while true:
        let ret = gzInflaterStep(inflater, addr inPtr, addr inLen,
                                 addr outPtr, addr outLen, gzNoFlush)
        check ret == gzOk or ret == gzStreamEnd or ret == gzBufError
        produced = outBuf.len - int(outLen)
        if ret == gzStreamEnd:
          break
        check inLen > 0 or outLen > 0
      check produced == expected.len
      check outBuf == expected

  test "set_dictionary and prime are accepted":
    let inflater = gzInflaterCreate()
    defer: gzInflaterDestroy(inflater)
    var dict = newSeq[byte](32768)
    check gzInflaterPrime(inflater, 3, 0x05) == gzOk
    check gzInflaterSetDictionary(inflater, addr dict[0],
                                  csize_t(dict.len)) == gzOk

  test "corrupt raw deflate is reported, not fatal":
    var bad = @[0x05'u8, 0xC1, 0x82, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]
    let inflater = gzInflaterCreate()
    defer: gzInflaterDestroy(inflater)
    var outBuf = newString(64)
    var inPtr = cast[ptr byte](addr bad[0])
    var inLen = csize_t(bad.len)
    var outPtr = cast[ptr byte](addr outBuf[0])
    var outLen = csize_t(outBuf.len)
    let ret = gzInflaterStep(inflater, addr inPtr, addr inLen,
                             addr outPtr, addr outLen, gzFinish)
    check ret == gzDataError or ret == gzBufError

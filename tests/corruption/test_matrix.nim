## Systematic public-decoder corruption and invalid-success checks.

import std/[options, os, streams, unittest]
import gzfast
import gzfast/gzip/members
import gzfast/source
import ../helpers/fixtures

type DecodeAttempt = object
  succeeded: bool
  output: string
  kind: GzFastErrorKind
  memberIndex: uint64

proc attempt(data: string; threads: int; limit: uint64): DecodeAttempt =
  let path = getTempDir() / "gzfast_corruption_attempt.gz"
  writeFile(path, data)
  var config = defaultGzFastConfig()
  config.threads = threads
  config.compressedGridSize = 1024
  config.outputLimit = some(limit)
  let input = initGzFastDecoder(config).open(path)
  try:
    var buffer = newString(257)
    while true:
      let count = input.readData(addr buffer[0], buffer.len)
      if count == 0: break
      result.output.add(buffer[0 ..< count])
    discard input.finish()
    result.succeeded = true
  except GzFastError as error:
    result.kind = error.kind
    result.memberIndex = error.memberIndex
  finally:
    input.close()
    removeFile(path)

proc decoded(data: string): string =
  let input = openGzFastSequential(newStringStream(data))
  defer: input.close()
  input.readAll()

suite "corruption matrix":
  test "every single-bit mutation is error or exact verified output":
    let valid = readFixture("small_text.gz")
    let expected = decoded(valid)
    for byteIndex in 0 ..< valid.len:
      for bit in 0 .. 7:
        var mutated = valid
        mutated[byteIndex] = char(byte(mutated[byteIndex]) xor byte(1 shl bit))
        let outcome = attempt(mutated, 1, uint64(expected.len + 1024))
        if outcome.succeeded:
          check outcome.output == expected
        else:
          check outcome.kind in {geInvalidHeader, geInvalidDeflate,
            geTruncatedInput, geChecksumMismatch, geSizeMismatch,
            geOutputLimit}

  test "truncation at every byte never succeeds":
    let valid = readFixture("small_text.gz")
    for cut in 0 ..< valid.len:
      let outcome = attempt(valid[0 ..< cut], 1, 10000)
      check not outcome.succeeded
      check outcome.kind in {geInvalidHeader, geInvalidDeflate,
                              geTruncatedInput, geChecksumMismatch,
                              geSizeMismatch}

  test "each footer byte is authenticated":
    let valid = readFixture("small_text.gz")
    for footerByte in 0 .. 7:
      var mutated = valid
      mutated[mutated.len - 8 + footerByte] =
        char(byte(mutated[mutated.len - 8 + footerByte]) xor 0x80)
      let outcome = attempt(mutated, 4, 10000)
      check not outcome.succeeded
      if footerByte < 4:
        check outcome.kind == geChecksumMismatch
      else:
        check outcome.kind == geSizeMismatch

  test "late concatenated-member corruption reports later member":
    var valid = readFixture("concat_3.gz")
    valid[^8] = char(byte(valid[^8]) xor 1)
    let outcome = attempt(valid, 4, 100000)
    check not outcome.succeeded
    check outcome.kind == geChecksumMismatch
    check outcome.memberIndex == 2
    check outcome.output.len <= fixtureByName("concat_3.gz").length.int

  test "selected dynamic payload mutations cannot silently alter output":
    let valid = readFixture("level9.gz")
    let expected = decoded(valid)
    let owner = openMemoryReadAtSource(toBytes(valid))
    let header = owner.view.parseHeaderAt(0, 1024 * 1024)
    owner.close()
    check header.status == hasOk
    for delta in [0, 1, 2, 3, 5, 8, 13, 21]:
      let index = int(header.payloadOffset) + delta
      if index >= valid.len - 8: continue
      var mutated = valid
      mutated[index] = char(byte(mutated[index]) xor 0x20)
      for workers in [1, 4]:
        let outcome = attempt(mutated, workers,
                              uint64(expected.len + 4096))
        if outcome.succeeded: check outcome.output == expected

  test "trailing junk and truncated later header are rejected":
    let valid = readFixture("small_text.gz")
    for suffix in ["\0", "junk", "\x1f\x8b\x08"]:
      let outcome = attempt(valid & suffix, 4, 10000)
      check not outcome.succeeded

  test "BGZF BSIZE and block footer mutations fail or safely fall back":
    let valid = readFixture("bgzf.gz")
    let expected = decoded(valid)
    for index in [16, 17, valid.len - 8, valid.len - 4]:
      var mutated = valid
      mutated[index] = char(byte(mutated[index]) xor 1)
      let outcome = attempt(mutated, 4, uint64(expected.len + 4096))
      if outcome.succeeded:
        check outcome.output == expected
      else:
        check outcome.kind in {geInvalidHeader, geInvalidDeflate,
          geTruncatedInput, geChecksumMismatch, geSizeMismatch}

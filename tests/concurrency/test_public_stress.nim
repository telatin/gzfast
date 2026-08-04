## Public decoder concurrency, slow-consumer, limits and many-member stress.

import std/[atomics, os, streams, typedthreads, unittest]
import gzfast
import gzfast/private/zlib_api
import ../helpers/[fixtures, gzip_builder]

type DecoderThreadArg = object
  path: string
  expectedLength: uint64
  expectedCrc: uint32
  failures: ptr Atomic[int]

proc decodeOnThread(arg: DecoderThreadArg) {.thread.} =
  try:
    {.cast(gcsafe).}:
      let input = openGzFast(arg.path, threads = 2)
      var buffer = newString(4097)
      var total = 0'u64
      var crc = 0'u32
      while true:
        let count = input.readData(addr buffer[0], buffer.len)
        if count == 0: break
        crc = gzCrc32(crc, cast[ptr byte](addr buffer[0]), csize_t(count))
        total += uint64(count)
      let report = input.finish()
      input.close()
      if total != arg.expectedLength or crc != arg.expectedCrc or
         not report.crcVerified:
        discard arg.failures[].fetchAdd(1)
  except CatchableError:
    discard arg.failures[].fetchAdd(1)

suite "public concurrency stress":
  test "multiple actual decoder instances run concurrently":
    let fixture = fixtureByName("bgzf.gz")
    var failures: Atomic[int]
    failures.store(0)
    var threads: array[4, Thread[DecoderThreadArg]]
    for i in 0 ..< threads.len:
      createThread(threads[i], decodeOnThread,
        DecoderThreadArg(path: fixturePath(fixture.name),
          expectedLength: fixture.length, expectedCrc: fixture.crc32,
          failures: addr failures))
    for i in 0 ..< threads.len: joinThread(threads[i])
    check failures.load() == 0

  test "one-byte slow consumer remains bounded":
    let fixture = fixtureByName("bgzf.gz")
    let input = openGzFast(fixturePath(fixture.name), threads = 4)
    var value: byte
    var total = 0'u64
    var crc = 0'u32
    while true:
      let count = input.readData(addr value, 1)
      if count == 0: break
      crc = gzCrc32(crc, addr value, 1)
      inc total
      if (total and 4095) == 0: sleep(1)
    let report = input.finish()
    input.close()
    check total == fixture.length
    check crc == fixture.crc32
    check report.peakBufferedBytes < 128'u64 * 1024 * 1024

  test "repeated stop-after-one-byte closes every backend":
    for name in ["small_text.gz", "bgzf.gz", "concat_3.gz"]:
      for _ in 0 ..< 40:
        let input = openGzFast(fixturePath(name), threads = 4)
        var value: byte
        discard input.readData(addr value, 1)
        input.close()

  test "thousands of empty and one-byte members stay ordered":
    for (name, expectedBytes) in [("empty.gz", 0), ("one_byte.gz", 1000)]:
      let path = getTempDir() / ("gzfast_many_" & name)
      let member = readFixture(name)
      var file: File
      check open(file, path, fmWrite)
      for _ in 0 ..< 1000: file.write(member)
      file.close()
      defer: removeFile(path)
      let input = openGzFast(path, threads = 8)
      var total = 0
      var buffer = newString(17)
      while true:
        let count = input.readData(addr buffer[0], buffer.len)
        if count == 0: break
        total += count
      let report = input.finish()
      input.close()
      check total == expectedBytes
      check report.memberCount == 1000
      check report.crcVerified
      check report.peakBufferedBytes < 256'u64 * 1024 * 1024

  test "output limit with outstanding BGZF and member jobs":
    for name in ["bgzf.gz", "concat_3.gz"]:
      var config = defaultGzFastConfig()
      config.threads = 8
      config.outputLimit = some(1000'u64)
      let input = initGzFastDecoder(config).open(fixturePath(name))
      var output = 0
      var buffer = newString(113)
      try:
        while true:
          let count = input.readData(addr buffer[0], buffer.len)
          if count == 0: break
          output += count
        check false
      except GzFastError as error:
        check error.kind == geOutputLimit
        check output <= 1000
      input.close()

  test "low memory ceiling safely selects fallback":
    let path = getTempDir() / "gzfast_memory_fallback.gz"
    writeFile(path, buildRepeatedGzip(2'u64 * 1024 * 1024))
    defer: removeFile(path)
    var config = defaultGzFastConfig()
    config.threads = 8
    config.compressedGridSize = 1024
    config.memoryLimit = 8 * 1024 * 1024
    let input = initGzFastDecoder(config).open(path)
    var total = 0'u64
    var buffer = newString(4096)
    while true:
      let count = input.readData(addr buffer[0], buffer.len)
      if count == 0: break
      total += uint64(count)
    let report = input.finish()
    input.close()
    check total == 2'u64 * 1024 * 1024
    check report.crcVerified

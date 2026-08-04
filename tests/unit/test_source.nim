## Milestone 4 tests for positional sources and 64-bit offsets.

import std/[atomics, os, typedthreads, unittest]
import gzfast/errors
import gzfast/source
import ../helpers/fixtures

type SourceThreadArg = object
  source: ReadAtSource
  failures: ptr Atomic[int]
  start: int

proc concurrentReader(arg: SourceThreadArg) {.thread.} =
  var buf: array[257, byte]
  for round in 0 ..< 200:
    let offset = (arg.start + round * 997) mod (256 * 1024 - buf.len)
    try:
      arg.source.readExactAt(uint64(offset), addr buf[0], buf.len)
      for i, value in buf:
        if value != byte((offset + i) mod 251):
          discard arg.failures[].fetchAdd(1)
          return
    except CatchableError:
      discard arg.failures[].fetchAdd(1)
      return

suite "positional ReadAtSource":
  test "path source snapshots size and reads arbitrary ranges":
    let path = fixturePath("random_256k.gz")
    let expected = readFile(path)
    let owner = openReadAtSource(path)
    defer: owner.close()
    check owner.view.size == uint64(expected.len)
    for (offset, length) in [(0, 1), (1, 31), (4093, 257),
                             (expected.len - 32, 64)]:
      var buf = newString(length)
      let n = owner.view.readAt(uint64(offset), addr buf[0], length)
      let wanted = min(length, expected.len - offset)
      check n == wanted
      check buf[0 ..< n] == expected[offset ..< offset + n]

  test "readExactAt rejects ranges outside snapshot":
    let owner = openReadAtSource(fixturePath("small_text.gz"))
    defer: owner.close()
    var buf: array[16, byte]
    expect GzFastError:
      owner.view.readExactAt(owner.view.size - 4, addr buf[0], buf.len)

  test "immutable memory source":
    var data = newSeq[byte](10000)
    for i in 0 ..< data.len:
      data[i] = byte(i mod 251)
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    var buf: array[511, byte]
    owner.view.readExactAt(777, addr buf[0], buf.len)
    for i, value in buf:
      check value == byte((777 + i) mod 251)

  test "concurrent reads do not share a file position":
    var data = newSeq[byte](256 * 1024)
    for i in 0 ..< data.len:
      data[i] = byte(i mod 251)
    let path = getTempDir() / "gzfast_concurrent_readat.bin"
    writeFile(path, toString(data))
    defer: removeFile(path)
    let owner = openReadAtSource(path)
    defer: owner.close()
    var failures: Atomic[int]
    failures.store(0)
    var threads: array[4, Thread[SourceThreadArg]]
    for i in 0 ..< threads.len:
      createThread(threads[i], concurrentReader,
        SourceThreadArg(source: owner.view, failures: addr failures,
                        start: i * 173))
    for i in 0 ..< threads.len:
      joinThread(threads[i])
    check failures.load() == 0

  test "offsets above 2 GiB remain 64-bit":
    let path = getTempDir() / "gzfast_sparse_64bit.bin"
    var file: File
    check open(file, path, fmWrite)
    let highOffset = 3'i64 * 1024 * 1024 * 1024 + 17
    file.setFilePos(highOffset)
    file.write('Z')
    file.close()
    defer: removeFile(path)
    let owner = openReadAtSource(path)
    defer: owner.close()
    check owner.view.size == uint64(highOffset + 1)
    var value: byte
    owner.view.readExactAt(uint64(highOffset), addr value, 1)
    check value == 'Z'.byte

  test "close is idempotent":
    let owner = openMemoryReadAtSource([1'u8, 2, 3])
    owner.close()
    owner.close()

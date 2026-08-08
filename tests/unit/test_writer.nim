## Public gzip writer tests.

import std/[os, streams, strutils, unittest]
import gzfast
import gzfast/private/zlib_api
import gzfast/private/writer_accounting

proc readGzip(path: string): string =
  let input = openGzFast(path, threads = 1)
  defer: input.close()
  result = input.readAll()
  discard input.finish()

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

suite "gzip writer":
  test "default writer emits a valid gzip stream and report":
    let path = getTempDir() / "gzfast_writer_default.gz"
    removeIfExists(path)
    defer: removeIfExists(path)
    let payload = "The quick brown fox jumps over the lazy dog.\n".repeat(1000)

    let writer = openGzFastWriter(path)
    check writer.writeString(payload) == payload.len
    let report = writer.finish()
    check writer.finish() == report
    writer.close()
    writer.close()

    check readGzip(path) == payload
    check report.uncompressedBytes == uint64(payload.len)
    check report.crc32 == crc32(payload)
    check report.isize == uint32(payload.len)
    check report.compressedBytes == uint64(getFileSize(path))

  test "close alone finishes the gzip member":
    let path = getTempDir() / "gzfast_writer_close.gz"
    removeIfExists(path)
    defer: removeIfExists(path)
    let payload = "close should write the trailer\n".repeat(200)

    let writer = openGzFastWriter(path)
    discard writer.writeString(payload)
    writer.close()
    writer.close()

    check readGzip(path) == payload

  test "empty stream is valid":
    let path = getTempDir() / "gzfast_writer_empty.gz"
    removeIfExists(path)
    defer: removeIfExists(path)

    let writer = openGzFastWriter(path)
    let report = writer.finish()
    writer.close()

    check readGzip(path) == ""
    check report.uncompressedBytes == 0
    check report.crc32 == 0
    check report.isize == 0

  test "small output buffer and many writes round-trip":
    let path = getTempDir() / "gzfast_writer_small_buffer.gz"
    removeIfExists(path)
    defer: removeIfExists(path)
    var config = defaultGzFastWriteConfig()
    config.outputBufferSize = 7
    config.level = 1
    let payload = "ACGTN0123456789\n".repeat(4096)

    let writer = openGzFastWriter(path, config)
    var offset = 0
    while offset < payload.len:
      let count = min(13, payload.len - offset)
      discard writer.writeData(cast[pointer](unsafeAddr payload[offset]), count)
      offset += count
    writer.close()

    check readGzip(path) == payload

  test "writeBytes and writeLine avoid caller-side string concatenation":
    let path = getTempDir() / "gzfast_writer_bytes_line.gz"
    removeIfExists(path)
    defer: removeIfExists(path)
    let payload = @[byte('a'), byte('b'), byte('c')]

    let writer = openGzFastWriter(path)
    check writer.writeBytes(payload) == payload.len
    writer.writeLine("def")
    writer.close()

    check readGzip(path) == "abcdef\n"

  test "sync flush preserves a valid final stream":
    let path = getTempDir() / "gzfast_writer_flush.gz"
    removeIfExists(path)
    defer: removeIfExists(path)

    let writer = openGzFastWriter(path)
    discard writer.writeString("first\n")
    writer.flush()
    writer.flush()
    discard writer.writeString("second\n")
    writer.close()

    check readGzip(path) == "first\nsecond\n"

  test "level zero writes a valid stored-style stream":
    let path = getTempDir() / "gzfast_writer_level0.gz"
    removeIfExists(path)
    defer: removeIfExists(path)
    var config = defaultGzFastWriteConfig()
    config.level = 0
    let payload = "already random-ish: 0123456789abcdef\n".repeat(1024)

    let writer = openGzFastWriter(path, config)
    discard writer.writeString(payload)
    let report = writer.finish()
    writer.close()

    check readGzip(path) == payload
    check report.uncompressedBytes == uint64(payload.len)

  test "borrowed file is left for the caller to close":
    let path = getTempDir() / "gzfast_writer_borrowed_file.gz"
    removeIfExists(path)
    defer: removeIfExists(path)
    var output: File
    check open(output, path, fmWrite)

    let writer = openGzFastWriter(output, ownsOutput = false)
    discard writer.writeString("borrowed\n")
    writer.close()
    output.close()

    check readGzip(path) == "borrowed\n"

  test "writer config validation":
    var config = defaultGzFastWriteConfig()
    config.validate()

    config.level = -1
    expect GzFastConfigError:
      config.validate()

    config = defaultGzFastWriteConfig()
    config.level = 10
    expect GzFastConfigError:
      config.validate()

    config = defaultGzFastWriteConfig()
    config.outputBufferSize = 0
    expect GzFastConfigError:
      config.validate()

    config = defaultGzFastWriteConfig()
    config.strategy = 5
    expect GzFastConfigError:
      config.validate()

  test "writing after close raises":
    let path = getTempDir() / "gzfast_writer_after_close.gz"
    removeIfExists(path)
    defer: removeIfExists(path)

    let writer = openGzFastWriter(path)
    writer.close()
    expect IOError:
      discard writer.writeString("late")

  test "writing after finish raises and repeated finish returns its report":
    let path = getTempDir() / "gzfast_writer_after_finish.gz"
    removeIfExists(path)
    defer: removeIfExists(path)

    let writer = openGzFastWriter(path)
    discard writer.writeString("complete")
    let report = writer.finish()

    expect IOError:
      discard writer.writeString("late")
    check writer.finish() == report
    writer.close()
    check writer.finish() == report

  test "invalid output path reports an output I/O error":
    let missingParent = getTempDir() / "gzfast_missing_writer_parent"
    let path = missingParent / "output.gz"
    if dirExists(missingParent):
      removeDir(missingParent)

    var caught = false
    try:
      discard openGzFastWriter(path)
    except GzFastError as e:
      caught = true
      check e.kind == geOutputIo
    check caught
    check not fileExists(path)

  test "nil output file reports an output I/O error":
    var caught = false
    try:
      discard openGzFastWriter(File(nil))
    except GzFastError as e:
      caught = true
      check e.kind == geOutputIo
    check caught

  test "ISIZE accounting wraps modulo 2^32":
    check gzipIsize(0xffff_ffff'u64) == 0xffff_ffff'u32
    check gzipIsize(0x1_0000_0000'u64) == 0'u32
    check gzipIsize(0x1_0000_0011'u64) == 17'u32
    check gzipIsize(0xffff_ffff_ffff_ffff'u64) == 0xffff_ffff'u32

  when defined(linux):
    test "finish failure poisons the writer and close still cleans up":
      var output: File
      check open(output, "/dev/full", fmWrite)
      let writer = openGzFastWriter(output, ownsOutput = true)
      discard writer.writeString("finish must surface the flush failure")

      var caught = false
      try:
        discard writer.finish()
      except GzFastError as e:
        caught = true
        check e.kind == geOutputIo
      check caught

      expect GzFastError:
        discard writer.writeString("late")
      writer.close()
      writer.close()

    test "close propagates finish failure and remains idempotent":
      var output: File
      check open(output, "/dev/full", fmWrite)
      let writer = openGzFastWriter(output, ownsOutput = true)
      discard writer.writeString("close must surface the flush failure")

      var caught = false
      try:
        writer.close()
      except GzFastError as e:
        caught = true
        check e.kind == geOutputIo
      check caught

      writer.close()
      expect GzFastError:
        discard writer.writeString("late")

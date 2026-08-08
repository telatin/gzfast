## GzFastWriter: forward-only gzip writer over the bundled zlib deflater.

import ./config, ./errors, ./report
import ./private/zlib_api

const gzipHeader = [
  0x1f'u8, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff
]

type
  GzFastWriter* = ref object
    ## Forward-only gzip writer. Not safe for concurrent calls from
    ## multiple threads.
    output: File
    ownsOutput: bool
    deflater: GzDeflaterHandle
    outBuf: seq[byte]
    crc: uint32
    uncompressedBytes: uint64
    compressedBytes: uint64
    finished: bool
    closeDone: bool
    failed: bool
    reportCache: GzipWriteReport

proc failWriter(w: GzFastWriter; kind: GzFastErrorKind; msg: string) =
  if not w.isNil:
    w.failed = true
  raise newGzFastError(kind, msg)

proc ensureWritable(w: GzFastWriter) =
  if w.isNil:
    raise newException(IOError, "gzfast: nil writer")
  if w.failed:
    raise newGzFastError(geInternal, "gzfast: writer is in a failed state")
  if w.closeDone:
    raise newException(IOError, "gzfast: writer is closed")
  if w.finished:
    raise newException(IOError, "gzfast: gzip member is already finished")
  if w.output.isNil:
    w.failWriter(geOutputIo, "gzfast: nil output file")
  if w.deflater.isNil:
    w.failWriter(geInternal, "gzfast: deflater is not initialized")

proc checkedWrite(w: GzFastWriter; data: pointer; len: int) =
  if len == 0:
    return
  var written = 0
  try:
    written = w.output.writeBuffer(data, len)
  except CatchableError as e:
    w.failWriter(geOutputIo, "output file write failed: " & e.msg)
  if written != len:
    w.failWriter(geOutputIo, "output file write failed")
  w.compressedBytes += uint64(len)

proc checkedFlush(w: GzFastWriter) =
  try:
    w.output.flushFile()
  except CatchableError as e:
    w.failWriter(geOutputIo, "output file flush failed: " & e.msg)

proc deflateFailed(w: GzFastWriter; status: cint) =
  w.failWriter(geInternal, "deflate failed with status " & $int(status))

proc writeLe32(w: GzFastWriter; value: uint32) =
  var bytes: array[4, byte]
  bytes[0] = byte(value and 0xff)
  bytes[1] = byte((value shr 8) and 0xff)
  bytes[2] = byte((value shr 16) and 0xff)
  bytes[3] = byte((value shr 24) and 0xff)
  w.checkedWrite(addr bytes[0], bytes.len)

proc writeGzipHeader(w: GzFastWriter) =
  var header = gzipHeader
  w.checkedWrite(addr header[0], header.len)

proc writeGzipTrailer(w: GzFastWriter) =
  w.writeLe32(w.crc)
  w.writeLe32(uint32(w.uncompressedBytes and 0xffff_ffff'u64))

proc runDeflate(w: GzFastWriter; input: ptr byte; inputLen: csize_t;
                flushMode: cint): cint =
  var inPtr = input
  var inLen = inputLen
  while true:
    let beforeIn = inLen
    var outPtr = cast[ptr byte](addr w.outBuf[0])
    var outLen = csize_t(w.outBuf.len)
    let status = gzDeflaterStep(w.deflater, addr inPtr, addr inLen,
                                addr outPtr, addr outLen, flushMode)
    let produced = w.outBuf.len - int(outLen)
    if produced > 0:
      w.checkedWrite(addr w.outBuf[0], produced)

    case flushMode
    of gzNoFlush:
      if status != gzOk:
        w.deflateFailed(status)
      if inLen == 0:
        return status
    of gzSyncFlush:
      if status == gzBufError and produced == 0 and beforeIn == inLen:
        return status
      if status != gzOk:
        w.deflateFailed(status)
      if outLen > 0:
        return status
    of gzFinish:
      if status == gzStreamEnd:
        return status
      if status != gzOk:
        w.deflateFailed(status)
    else:
      w.deflateFailed(status)

    if produced == 0 and beforeIn == inLen:
      w.deflateFailed(gzBufError)

proc openGzFastWriter*(output: File;
                       config = defaultGzFastWriteConfig();
                       ownsOutput = false): GzFastWriter =
  ## Open a gzip writer around an existing `File`.
  ##
  ## When `ownsOutput` is true, `close` also closes `output`; otherwise the
  ## caller remains responsible for closing it.
  if output.isNil:
    raise newGzFastError(geOutputIo, "nil output file")
  config.validate()
  let deflater = gzDeflaterCreate(cint(config.level), cint(config.strategy))
  if deflater.isNil:
    raise newGzFastError(geInternal, "cannot initialize deflater")
  result = GzFastWriter(
    output: output,
    ownsOutput: ownsOutput,
    deflater: deflater,
    outBuf: newSeq[byte](config.outputBufferSize),
    crc: 0
  )
  try:
    result.writeGzipHeader()
  except CatchableError:
    if not result.deflater.isNil:
      gzDeflaterDestroy(result.deflater)
      result.deflater = nil
    if ownsOutput:
      output.close()
    raise

proc openGzFastWriter*(path: string;
                       config = defaultGzFastWriteConfig()): GzFastWriter =
  ## Create or truncate `path` and open it for gzip writing.
  config.validate()
  var output: File
  if not open(output, path, fmWrite):
    raise newGzFastError(geOutputIo, "cannot open output file: " & path)
  try:
    result = openGzFastWriter(output, config, ownsOutput = false)
    result.ownsOutput = true
  except CatchableError:
    output.close()
    raise

proc writeData*(w: GzFastWriter; data: pointer; len: int): int =
  ## Compress exactly `len` bytes from `data`.
  ##
  ## Returns `len` on success. Any short output write or deflate failure raises.
  w.ensureWritable()
  if len < 0:
    raise newException(ValueError, "write length must be >= 0")
  if len == 0:
    return 0
  if data.isNil:
    raise newException(ValueError, "write data pointer is nil")
  discard w.runDeflate(cast[ptr byte](data), csize_t(len), gzNoFlush)
  w.crc = gzCrc32(w.crc, cast[ptr byte](data), csize_t(len))
  w.uncompressedBytes += uint64(len)
  len

proc writeString*(w: GzFastWriter; s: string): int =
  ## Compress the bytes in `s`.
  if s.len == 0:
    return w.writeData(nil, 0)
  w.writeData(cast[pointer](unsafeAddr s[0]), s.len)

proc writeBytes*(w: GzFastWriter; data: openArray[byte]): int =
  ## Compress the bytes in `data`.
  if data.len == 0:
    return w.writeData(nil, 0)
  w.writeData(cast[pointer](unsafeAddr data[0]), data.len)

proc writeLine*(w: GzFastWriter; s: string) =
  ## Compress `s` followed by a newline byte.
  discard w.writeString(s)
  var nl = '\n'
  discard w.writeData(addr nl, 1)

proc flush*(w: GzFastWriter) =
  ## Make compressed bytes written so far visible to the underlying file.
  ##
  ## This uses zlib's sync flush and can reduce compression ratio when called
  ## frequently.
  if w.isNil:
    raise newException(IOError, "gzfast: nil writer")
  if w.closeDone:
    raise newException(IOError, "gzfast: writer is closed")
  if w.failed:
    raise newGzFastError(geInternal, "gzfast: writer is in a failed state")
  if w.finished:
    if not w.output.isNil:
      w.checkedFlush()
    return
  w.ensureWritable()
  discard w.runDeflate(nil, 0, gzSyncFlush)
  w.checkedFlush()

proc finish*(w: GzFastWriter): GzipWriteReport =
  ## Finish the gzip member, write the trailer, and return deterministic stats.
  ##
  ## The underlying file remains open; call `close` when using a writer that
  ## owns its file.
  if w.isNil:
    raise newException(IOError, "gzfast: nil writer")
  if w.finished:
    return w.reportCache
  if w.closeDone:
    raise newException(IOError, "gzfast: writer is closed")
  w.ensureWritable()
  try:
    discard w.runDeflate(nil, 0, gzFinish)
    gzDeflaterDestroy(w.deflater)
    w.deflater = nil
    w.writeGzipTrailer()
    w.checkedFlush()
    w.finished = true
    w.reportCache = GzipWriteReport(
      compressedBytes: w.compressedBytes,
      uncompressedBytes: w.uncompressedBytes,
      crc32: w.crc,
      isize: uint32(w.uncompressedBytes and 0xffff_ffff'u64)
    )
    w.reportCache
  except CatchableError:
    if not w.deflater.isNil:
      gzDeflaterDestroy(w.deflater)
      w.deflater = nil
    w.failed = true
    raise

proc close*(w: GzFastWriter) =
  ## Finish the gzip member and release owned resources. Idempotent.
  if w.isNil or w.closeDone:
    return
  try:
    if not w.failed and not w.finished:
      discard w.finish()
  finally:
    if not w.deflater.isNil:
      gzDeflaterDestroy(w.deflater)
      w.deflater = nil
    if w.ownsOutput and not w.output.isNil:
      w.output.close()
      w.output = nil
    w.closeDone = true

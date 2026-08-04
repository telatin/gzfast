## Authoritative sequential gzip decoder.
##
## This is the one-thread implementation, the fallback for
## non-positional sources, and the correctness oracle for the parallel
## paths. It streams compressed input and decoded output through
## bounded buffers only; nothing here is proportional to file size.

import std/[options, streams]
import ../config, ../errors, ../report
import ../private/zlib_api
import ../gzip/header, ../gzip/footer

const
  footerLen = 8

type
  SequentialSourceKind = enum
    sskFile
    sskStream

  SequentialSource = object
    case kind: SequentialSourceKind
    of sskFile: f: File
    of sskStream: s: Stream

  SeqState = enum
    smHeader    ## expect a new member header (or clean EOF after >=1 member)
    smInflate   ## inside raw DEFLATE payload
    smFooter    ## expect the 8-byte trailer
    smDone      ## final trailer verified

  SequentialDecoder* = object
    src: SequentialSource
    ownsSource: bool
    config: GzFastConfig
    inflater: GzInflaterHandle
    inBuf: seq[byte]
    inStart, inEnd: int
    baseOffset: uint64      ## absolute compressed offset of inBuf[0]
    physicalEof: bool
    hdr: GzipHeaderParser
    hdrCrc: uint32          ## running CRC32 over header bytes
    hdrCount: int           ## header bytes fed for the current member
    footerBuf: array[footerLen, byte]
    footerHave: int
    outBuf: seq[byte]
    outPos, outLen: int
    state: SeqState
    crc: uint32             ## running member CRC32
    memberLen: uint64       ## decoded bytes in current member
    totalOut: uint64
    memberCount: uint64
    peakBuffered: uint64

proc currentOffset(dec: SequentialDecoder): uint64 =
  ## Absolute compressed offset of the next unconsumed byte.
  dec.baseOffset + dec.inStart.uint64

proc updatePeak(dec: var SequentialDecoder) =
  let live = uint64(dec.inBuf.len + dec.outBuf.len + dec.hdrCount)
  if live > dec.peakBuffered:
    dec.peakBuffered = live

proc initDecoder(src: SequentialSource; ownsSource: bool;
                 config: GzFastConfig): SequentialDecoder =
  result = SequentialDecoder(
    src: src,
    ownsSource: ownsSource,
    config: config,
    inflater: gzInflaterCreate(),
    state: smHeader,
    hdr: initGzipHeaderParser()
  )
  if result.inflater.isNil:
    raise newGzFastError(geInternal, "failed to allocate inflate state")
  result.inBuf = newSeq[byte](config.inputPageSize)
  result.outBuf = newSeq[byte](config.decodedChunkSize)
  result.updatePeak()

proc openSequentialDecoder*(path: string;
                            config: GzFastConfig): SequentialDecoder =
  ## Open `path` for authoritative sequential decoding.
  var f: File
  if not open(f, path, fmRead):
    raise newGzFastError(geInputIo, "cannot open input file: " & path)
  initDecoder(SequentialSource(kind: sskFile, f: f), true, config)

proc openSequentialDecoderAt*(path: string; offset: uint64;
                              config: GzFastConfig): SequentialDecoder =
  ## Start at a verified gzip member boundary. Used after a specialised
  ## parallel path commits earlier independent members.
  if offset > uint64(high(int64)):
    raise newGzFastError(geInputIo, "compressed offset is not seekable", offset)
  var f: File
  if not open(f, path, fmRead):
    raise newGzFastError(geInputIo, "cannot open input file: " & path, offset)
  try:
    f.setFilePos(int64(offset))
  except CatchableError as error:
    f.close()
    raise newGzFastError(geInputIo, "cannot seek input file: " & error.msg,
                         offset)
  result = initDecoder(SequentialSource(kind: sskFile, f: f), true, config)
  result.baseOffset = offset

proc openSequentialDecoder*(input: Stream;
                            config: GzFastConfig): SequentialDecoder =
  ## Decode from a non-positional stream (pipe, socket, memory). The
  ## stream is *not* closed by the decoder.
  if input.isNil:
    raise newGzFastError(geInputIo, "nil input stream")
  initDecoder(SequentialSource(kind: sskStream, s: input), false, config)

proc close*(dec: var SequentialDecoder) =
  ## Release the inflater and, when owned, the input file. Idempotent.
  if not dec.inflater.isNil:
    gzInflaterDestroy(dec.inflater)
    dec.inflater = nil
  if dec.ownsSource and dec.src.kind == sskFile and
     not dec.src.f.isNil:
    dec.src.f.close()
    dec.src.f = nil

proc refill(dec: var SequentialDecoder): bool =
  ## Ensure at least one compressed byte is buffered. False at EOF.
  if dec.inStart < dec.inEnd:
    return true
  if dec.physicalEof:
    return false
  dec.baseOffset += dec.inEnd.uint64
  dec.inStart = 0
  var n: int
  case dec.src.kind
  of sskFile:
    n = dec.src.f.readBytes(dec.inBuf, 0, dec.inBuf.len)
  of sskStream:
    n = dec.src.s.readData(addr dec.inBuf[0], dec.inBuf.len)
  dec.inEnd = n
  if n == 0:
    dec.physicalEof = true
    return false
  true

proc parseMemberHeader(dec: var SequentialDecoder) =
  ## Consume one member header. At a clean member boundary, physical
  ## EOF ends decoding; a truncated header is an error.
  if not dec.refill():
    if dec.memberCount == 0:
      raise newGzFastError(geTruncatedInput,
        "empty input: no gzip member found", dec.currentOffset, 0)
    dec.state = smDone
    return
  dec.hdr = initGzipHeaderParser()
  dec.hdrCrc = 0
  dec.hdrCount = 0
  while true:
    if not dec.refill():
      raise newGzFastError(geTruncatedInput,
        "truncated gzip header", dec.currentOffset, dec.memberCount)
    if dec.hdrCount >= dec.config.maxHeaderSize:
      raise newGzFastError(geInvalidHeader,
        "gzip header exceeds maxHeaderSize (" & $dec.config.maxHeaderSize &
        " bytes)", dec.currentOffset, dec.memberCount)
    let b = dec.inBuf[dec.inStart]
    inc dec.inStart
    dec.hdrCrc = crc32([b], dec.hdrCrc)
    inc dec.hdrCount
    let r = dec.hdr.feed(b, dec.hdrCrc)
    case r.kind
    of hfNeedMore:
      discard
    of hfDone:
      break
    of hfError:
      raise newGzFastError(geInvalidHeader, r.msg,
        dec.currentOffset - 1, dec.memberCount)
  dec.updatePeak()
  # BGZF block-size validation and the specialised BGZF path arrive in
  # a later milestone; the generic path verifies every member anyway.
  if gzInflaterReset(dec.inflater) != gzOk:
    raise newGzFastError(geInternal, "inflate reset failed",
      dec.currentOffset, dec.memberCount)
  dec.crc = 0
  dec.memberLen = 0
  dec.state = smInflate

proc mapInflateError(dec: SequentialDecoder; ret: cint): ref GzFastError =
  case ret
  of gzDataError:
    newGzFastError(geInvalidDeflate, "invalid DEFLATE data",
      dec.currentOffset, dec.memberCount)
  of gzMemError:
    newGzFastError(geInternal, "inflate out of memory",
      dec.currentOffset, dec.memberCount)
  else:
    newGzFastError(geInternal, "unexpected inflate status " & $ret,
      dec.currentOffset, dec.memberCount)

proc inflateSome(dec: var SequentialDecoder) =
  ## Run inflate until at least one output byte is buffered, the member
  ## ends, or an error/limit is hit.
  while dec.outPos == dec.outLen and dec.state == smInflate:
    if not dec.refill():
      raise newGzFastError(geTruncatedInput,
        "truncated DEFLATE stream", dec.currentOffset, dec.memberCount)

    var inPtr = addr dec.inBuf[dec.inStart]
    var inLen = csize_t(dec.inEnd - dec.inStart)
    let inLenBefore = inLen

    var outSpace = dec.outBuf.len - dec.outLen
    if dec.config.outputLimit.isSome:
      let remaining = dec.config.outputLimit.get - dec.totalOut
      if remaining < outSpace.uint64:
        outSpace = remaining.int
    var outPtr = addr dec.outBuf[dec.outLen]
    var outLen = csize_t(outSpace)

    let ret = gzInflaterStep(dec.inflater, addr inPtr, addr inLen,
                             addr outPtr, addr outLen, gzNoFlush)
    let consumed = int(inLenBefore - inLen)
    let produced = outSpace - int(outLen)
    dec.inStart += consumed

    if produced > 0:
      dec.crc = gzCrc32(dec.crc, addr dec.outBuf[dec.outLen],
                        produced.csize_t)
      dec.memberLen += produced.uint64
      dec.totalOut += produced.uint64
      dec.outLen += produced

    case ret
    of gzStreamEnd:
      dec.state = smFooter
      dec.footerHave = 0
    of gzOk, gzBufError:
      # Z_BUF_ERROR with avail_out clamped to zero means the output
      # limit was reached but more output is pending.
      if dec.config.outputLimit.isSome and
         dec.totalOut >= dec.config.outputLimit.get and
         produced == 0 and ret == gzBufError:
        raise newGzFastError(geOutputLimit,
          "decoded output exceeds the configured outputLimit",
          dec.currentOffset, dec.memberCount)
      if consumed == 0 and produced == 0 and ret == gzBufError:
        # No progress possible: inflate needs more input.
        if dec.inStart == dec.inEnd:
          if not dec.refill():
            raise newGzFastError(geTruncatedInput,
              "truncated DEFLATE stream", dec.currentOffset, dec.memberCount)
    else:
      raise dec.mapInflateError(ret)

    # If the limit was reached exactly and the stream did not end, the
    # next loop iteration triggers the zero-space probe above.
    if dec.config.outputLimit.isSome and
       dec.totalOut >= dec.config.outputLimit.get and
       dec.outPos < dec.outLen:
      return

proc parseMemberFooter(dec: var SequentialDecoder) =
  while dec.footerHave < footerLen:
    if not dec.refill():
      raise newGzFastError(geTruncatedInput,
        "truncated gzip member trailer", dec.currentOffset, dec.memberCount)
    let take = min(footerLen - dec.footerHave, dec.inEnd - dec.inStart)
    copyMem(addr dec.footerBuf[dec.footerHave], addr dec.inBuf[dec.inStart],
            take)
    dec.inStart += take
    dec.footerHave += take

  let f = parseGzipFooter(dec.footerBuf)
  let footerOffset = dec.currentOffset - footerLen.uint64
  if f.crc32 != dec.crc:
    raise newGzFastError(geChecksumMismatch,
      "gzip member CRC32 mismatch (computed " & $dec.crc &
      ", stored " & $f.crc32 & ")",
      footerOffset, dec.memberCount)
  if f.isize != uint32(dec.memberLen and 0xFFFF_FFFF'u64):
    raise newGzFastError(geSizeMismatch,
      "gzip member ISIZE mismatch (decoded " &
      $uint32(dec.memberLen and 0xFFFF_FFFF'u64) &
      ", stored " & $f.isize & ")",
      footerOffset, dec.memberCount)
  inc dec.memberCount
  dec.state = smHeader

proc fillOutput(dec: var SequentialDecoder) =
  ## Ensure at least one decoded byte is available or decoding is done.
  while dec.outPos == dec.outLen and dec.state != smDone:
    case dec.state
    of smHeader:
      dec.parseMemberHeader()
    of smInflate:
      dec.outPos = 0
      dec.outLen = 0
      dec.inflateSome()
    of smFooter:
      dec.parseMemberFooter()
    of smDone:
      discard

proc readData*(dec: var SequentialDecoder; buffer: pointer;
               bufLen: int): int =
  ## Read up to `bufLen` decoded bytes. Returns 0 only at verified EOF.
  if bufLen <= 0:
    return 0
  
  # Loop to fill the buffer as much as possible across member boundaries.
  # Stop when we hit EOF, outputLimit, or have filled the buffer.
  var totalRead = 0
  var destPtr = buffer
  
  while totalRead < bufLen:
    # Check if we've hit the outputLimit before trying to decode more
    if dec.config.outputLimit.isSome and 
       dec.totalOut >= dec.config.outputLimit.get:
      # We've reached the limit. If we've already read some data, return it.
      # Otherwise, let fillOutput raise the exception on the next call.
      if totalRead > 0:
        break
    
    dec.fillOutput()
    let avail = dec.outLen - dec.outPos
    if avail == 0:
      # No data available. If we're not done, there might be more members.
      # But if we've already read some data, return it and let the next
      # readData call handle the next member (or raise outputLimit).
      if totalRead > 0:
        break
      # Otherwise, we're truly at EOF
      break
    
    let toRead = min(bufLen - totalRead, avail)
    copyMem(destPtr, addr dec.outBuf[dec.outPos], toRead)
    dec.outPos += toRead
    totalRead += toRead
    destPtr = cast[pointer](cast[uint](destPtr) + uint(toRead))
    
    # If we've consumed all available output and the decoder is done, stop.
    # Otherwise, keep looping to get more data from subsequent members.
    if dec.outPos == dec.outLen and dec.state == smDone:
      break
  
  result = totalRead

proc atEnd*(dec: var SequentialDecoder): bool =
  ## True when the complete input has been decoded and verified.
  dec.fillOutput()
  dec.outPos == dec.outLen and dec.state == smDone

proc verifyRemaining*(dec: var SequentialDecoder) =
  ## Decode and discard all remaining output, verifying the input.
  while true:
    dec.fillOutput()
    if dec.outPos == dec.outLen and dec.state == smDone:
      return
    dec.outPos = dec.outLen

proc report*(dec: SequentialDecoder): DecodeReport =
  DecodeReport(
    compressedBytes: dec.currentOffset(),
    decompressedBytes: dec.totalOut,
    memberCount: dec.memberCount,
    pathsUsed: {dpSequential},
    crcVerified: dec.state == smDone,
    peakWorkers: 1,
    peakBufferedBytes: dec.peakBuffered
  )

proc statsSnapshot*(dec: SequentialDecoder): DecoderStats =
  DecoderStats(
    compressedBytes: dec.currentOffset(),
    decompressedBytes: dec.totalOut,
    memberCount: dec.memberCount,
    activeWorkers: 1,
    bufferedBytes: uint64(dec.outLen - dec.outPos) +
                   uint64(dec.inEnd - dec.inStart),
    finished: dec.state == smDone
  )

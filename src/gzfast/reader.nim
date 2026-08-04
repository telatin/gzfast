## GzFastStream: a forward-only std/streams-compatible reader.

import std/streams
import ./config, ./errors, ./report
import ./paths/member_parallel
import ./paths/marker
import ./paths/sequential

type
  ReaderBackend = enum
    rbSequential
    rbParallelMembers
    rbMarker

  GzFastStream* = ref object of StreamObj
    ## Forward-only decompression stream. Seeking is unsupported.
    ## Not safe for concurrent calls from multiple consumer threads;
    ## may be moved between threads when no call is in progress.
    backend: ReaderBackend
    dec: SequentialDecoder
    parallelDec: ParallelMemberDecoder
    markerDec: MarkerPathDecoder
    closed: bool
    cancelled: bool

proc gsReadData(s: Stream; buffer: pointer; bufLen: int): int
    {.nimcall, gcsafe, tags: [ReadIOEffect], raises: [IOError, OSError].} =
  let gs = GzFastStream(s)
  if gs.closed:
    raise newException(IOError, "gzfast: stream is closed")
  if gs.cancelled:
    raise newGzFastError(geCancelled, "gzfast: decoding was cancelled")
  case gs.backend
  of rbSequential: gs.dec.readData(buffer, bufLen)
  of rbParallelMembers:
    {.cast(raises: [IOError, OSError]), cast(tags: [ReadIOEffect]).}:
      gs.parallelDec.readData(buffer, bufLen)
  of rbMarker:
    {.cast(raises: [IOError, OSError]), cast(tags: [ReadIOEffect]).}:
      gs.markerDec.readData(buffer, bufLen)

proc gsReadDataStr(s: Stream; buffer: var string; slice: Slice[int]): int
    {.nimcall, gcsafe, tags: [ReadIOEffect], raises: [IOError, OSError].} =
  let gs = GzFastStream(s)
  if gs.closed:
    raise newException(IOError, "gzfast: stream is closed")
  if gs.cancelled:
    raise newGzFastError(geCancelled, "gzfast: decoding was cancelled")
  if slice.b < slice.a:
    return 0
  case gs.backend
  of rbSequential:
    gs.dec.readData(addr buffer[slice.a], slice.b - slice.a + 1)
  of rbParallelMembers:
    {.cast(raises: [IOError, OSError]), cast(tags: [ReadIOEffect]).}:
      gs.parallelDec.readData(addr buffer[slice.a], slice.b - slice.a + 1)
  of rbMarker:
    {.cast(raises: [IOError, OSError]), cast(tags: [ReadIOEffect]).}:
      gs.markerDec.readData(addr buffer[slice.a], slice.b - slice.a + 1)

proc gsAtEnd(s: Stream): bool
    {.nimcall, gcsafe, tags: [ReadIOEffect], raises: [IOError, OSError].} =
  let gs = GzFastStream(s)
  if gs.closed:
    return true
  if gs.cancelled:
    return true
  case gs.backend
  of rbSequential: gs.dec.atEnd()
  of rbParallelMembers:
    {.cast(raises: [IOError, OSError]), cast(tags: [ReadIOEffect]).}:
      gs.parallelDec.atEnd()
  of rbMarker:
    {.cast(raises: [IOError, OSError]), cast(tags: [ReadIOEffect]).}:
      gs.markerDec.atEnd()

proc gsClose(s: Stream)
    {.nimcall, gcsafe, tags: [WriteIOEffect], raises: [IOError, OSError].} =
  let gs = GzFastStream(s)
  if not gs.closed:
    gs.closed = true
    case gs.backend
    of rbSequential: gs.dec.close()
    of rbParallelMembers:
      {.cast(raises: [IOError, OSError]), cast(tags: [WriteIOEffect]).}:
        gs.parallelDec.close()
    of rbMarker:
      {.cast(raises: [IOError, OSError]), cast(tags: [WriteIOEffect]).}:
        gs.markerDec.close()

proc gsUnsupported(s: Stream; pos: int)
    {.nimcall, gcsafe, tags: [], raises: [IOError].} =
  ## The stream is forward-only: seeking never silently restarts
  ## decompression, it is simply unsupported.
  raise newException(IOError, "gzfast: seeking is not supported")

proc gsUnsupportedPos(s: Stream): int
    {.nimcall, gcsafe, tags: [], raises: [IOError].} =
  raise newException(IOError, "gzfast: seeking is not supported")

proc gsUnsupportedPeek(s: Stream; buffer: pointer; bufLen: int): int
    {.nimcall, gcsafe, tags: [ReadIOEffect], raises: [IOError].} =
  raise newException(IOError, "gzfast: peeking is not supported")

proc gsUnsupportedWrite(s: Stream; buffer: pointer; bufLen: int)
    {.nimcall, gcsafe, tags: [WriteIOEffect], raises: [IOError].} =
  raise newException(IOError, "gzfast: stream is read-only")

proc gsFlush(s: Stream)
    {.nimcall, gcsafe, tags: [WriteIOEffect], raises: [].} =
  discard # read-only stream: nothing to flush

proc newGzFastStream(dec: SequentialDecoder): GzFastStream =
  result = GzFastStream(dec: dec, backend: rbSequential)
  result.readDataImpl = gsReadData
  result.readDataStrImpl = gsReadDataStr
  result.atEndImpl = cast[typeof(result.atEndImpl)](gsAtEnd)
  result.closeImpl = gsClose
  result.setPositionImpl = gsUnsupported
  result.getPositionImpl = gsUnsupportedPos
  result.peekDataImpl = gsUnsupportedPeek
  result.writeDataImpl = gsUnsupportedWrite
  result.flushImpl = gsFlush

proc newGzFastStream(dec: ParallelMemberDecoder): GzFastStream =
  result = GzFastStream(parallelDec: dec, backend: rbParallelMembers)
  result.readDataImpl = gsReadData
  result.readDataStrImpl = gsReadDataStr
  # atEnd must look ahead into the compressed input, which performs
  # reads. The std/streams atEndImpl vtable slot is typed tags: [],
  # so the ReadIOEffect is set aside with an explicit proc-type cast.
  result.atEndImpl = cast[typeof(result.atEndImpl)](gsAtEnd)
  result.closeImpl = gsClose
  # std/streams calls vtable procs unconditionally, so unsupported
  # operations get explicit raising implementations instead of nil.
  result.setPositionImpl = gsUnsupported
  result.getPositionImpl = gsUnsupportedPos
  result.peekDataImpl = gsUnsupportedPeek
  result.writeDataImpl = gsUnsupportedWrite
  result.flushImpl = gsFlush

proc newGzFastStream(dec: MarkerPathDecoder): GzFastStream =
  result = GzFastStream(markerDec: dec, backend: rbMarker)
  result.readDataImpl = gsReadData
  result.readDataStrImpl = gsReadDataStr
  result.atEndImpl = cast[typeof(result.atEndImpl)](gsAtEnd)
  result.closeImpl = gsClose
  result.setPositionImpl = gsUnsupported
  result.getPositionImpl = gsUnsupportedPos
  result.peekDataImpl = gsUnsupportedPeek
  result.writeDataImpl = gsUnsupportedWrite
  result.flushImpl = gsFlush

proc openGzFastStreamFromPath*(path: string;
                               config: GzFastConfig): GzFastStream =
  let parallel = tryOpenParallelMemberDecoder(path, config)
  if not parallel.isNil:
    newGzFastStream(parallel)
  else:
    let markerDecoder = tryOpenMarkerPath(path, config)
    if not markerDecoder.isNil:
      newGzFastStream(markerDecoder)
    else:
      newGzFastStream(openSequentialDecoder(path, config))

proc openGzFastStreamFromStream*(input: Stream;
                                 config: GzFastConfig): GzFastStream =
  newGzFastStream(openSequentialDecoder(input, config))

proc finish*(reader: GzFastStream): DecodeReport =
  ## If EOF has already been reached, return the completed report.
  ## Otherwise discard subsequent decoded output while continuing to
  ## decode and verify the complete compressed stream.
  if reader.closed:
    raise newException(IOError, "gzfast: stream is closed")
  if reader.cancelled:
    raise newGzFastError(geCancelled, "gzfast: decoding was cancelled")
  case reader.backend
  of rbSequential:
    reader.dec.verifyRemaining()
    reader.dec.report()
  of rbParallelMembers:
    reader.parallelDec.verifyRemaining()
    reader.parallelDec.report()
  of rbMarker:
    reader.markerDec.verifyRemaining()
    reader.markerDec.report()

proc cancel*(reader: GzFastStream) =
  ## Stop unread work and release resources.
  if not reader.cancelled:
    reader.cancelled = true
    case reader.backend
    of rbSequential: reader.dec.close()
    of rbParallelMembers: reader.parallelDec.close()
    of rbMarker: reader.markerDec.close()

proc stats*(reader: GzFastStream): DecoderStats =
  ## Approximate snapshot of decoder progress.
  if reader.closed or reader.cancelled:
    result.finished = true
  else:
    case reader.backend
    of rbSequential: result = reader.dec.statsSnapshot()
    of rbParallelMembers: result = reader.parallelDec.statsSnapshot()
    of rbMarker: result = reader.markerDec.statsSnapshot()

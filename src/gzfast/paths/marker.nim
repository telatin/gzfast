## Rolling marker/window parallel path for ordinary single-member gzip.

import std/[cpuinfo, options]
import ../buffers, ../config, ../errors, ../report, ../source
import ../gzip/[footer, members]
import ../private/zlib_api
import ../deflate/[bitreader, blockfinder, dynamic_header, exact_decode,
                   marker_decode, marker_resolve]
import ../scheduler/[bounded_queue, controller, jobs]
import ../scheduler/adaptive
import ./sequential

type
  MarkerPathDecoder* = ref object
    path: string
    config: GzFastConfig
    sourceOwner: OwnedReadAtSource
    payloadBit: uint64
    currentBit: uint64
    window: ResolvedWindow
    horizon: int
    workers: int
    finderWorkspace: DynamicHeaderWorkspace
    runtime: MarkerRuntime
    firstBatchStarts: seq[uint64] ## probed at open; consumed by first batch
    nextOrdinal: uint64
    resolutionTracker: AllocationTracker
    pending: seq[SharedBuffer] # bounded by horizon + exact bridge
    pendingIndex: int
    pendingPos: int
    totalOut: uint64
    memberBytes: uint64
    memberCrc: uint32
    memberCount: uint64
    peakWorkers: int
    peakBuffered: uint64
    fallback: SequentialDecoder
    hasFallback: bool
    fallbackReplaysMember: bool
    paths: set[DecodePath]
    done: bool
    closed: bool

proc sizing(config: GzFastConfig): tuple[workers, horizon: int] =
  var workers = if config.threads > 0: config.threads
                else: initialWorkerTarget(min(max(countProcessors(), 1), 16))
  var horizon = if config.inFlightChunks > 0: config.inFlightChunks
                else: workers + 2
  let ceiling = if config.memoryLimit > 0: config.memoryLimit
                else: 512'i64 * 1024 * 1024
  proc estimate(): int64 =
    int64(workers) * int64(config.inputPageSize + 3 * 64 * 1024) +
      int64(horizon) * int64(config.maxSpeculativeOutput) * 3
  while horizon > 1 and estimate() > ceiling: dec horizon
  while workers > 1 and estimate() > ceiling:
    dec workers
    horizon = min(horizon, workers + 2)
  if estimate() > ceiling: (0, 0) else: (workers, max(horizon, 1))

proc findCandidate(decoder: MarkerPathDecoder; fromBit: uint64;
                   candidate: var DynamicCandidate): bool =
  let sourceBits = decoder.sourceOwner.view.size * 8
  let span = uint64(decoder.config.compressedGridSize) * 8
  let stop = min(sourceBits, fromBit + span)
  findNextDynamicCandidate(decoder.sourceOwner.view, fromBit, stop,
    decoder.finderWorkspace, candidate,
    min(decoder.config.inputPageSize, BitReaderPageCapacity))

proc collectBatchStarts(decoder: MarkerPathDecoder): seq[uint64] =
  ## Starting points for the next batch: the authoritative position plus
  ## one speculative candidate per grid span, up to the horizon.
  result = @[decoder.currentBit]
  var search = decoder.currentBit +
    uint64(decoder.config.compressedGridSize) * 8
  while result.len <= decoder.horizon:
    var candidate: DynamicCandidate
    if not decoder.findCandidate(search, candidate): break
    if candidate.startBit <= result[^1]: break
    result.add(candidate.startBit)
    search = candidate.startBit +
      uint64(decoder.config.compressedGridSize) * 8

proc account(decoder: MarkerPathDecoder; buffer: SharedBuffer)
proc releasePending(decoder: MarkerPathDecoder)

proc tryOpenMarkerPath*(path: string; config: GzFastConfig): MarkerPathDecoder =
  if config.threads == 1 or not config.enableMarkerPath:
    return nil
  let calculated = sizing(config)
  if calculated.workers < 2:
    return nil
  let owner = openReadAtSource(path)
  let header = owner.view.parseHeaderAt(0, config.maxHeaderSize)
  if header.status != hasOk or header.info.bgzfBlockSize > 0:
    owner.close()
    return nil
  # Small members cannot fill two grid spans, so speculation cannot
  # overlap; the optimized sequential zlib path is strictly faster.
  if owner.view.size - header.payloadOffset <
      2 * uint64(config.compressedGridSize):
    owner.close()
    return nil
  let payloadBit = header.payloadOffset * 8
  let finderWorkspace = newDynamicHeaderWorkspace()
  var candidate: DynamicCandidate
  if not findNextDynamicCandidate(owner.view, payloadBit,
      min(owner.view.size * 8,
          payloadBit + uint64(config.compressedGridSize) * 8),
      finderWorkspace, candidate,
      min(config.inputPageSize, BitReaderPageCapacity)):
    owner.close()
    return nil
  result = MarkerPathDecoder(path: path, config: config,
    sourceOwner: owner, payloadBit: payloadBit, currentBit: payloadBit,
    horizon: calculated.horizon, workers: calculated.workers,
    finderWorkspace: finderWorkspace,
    paths: {dpMarkerWindow})
  result.resolutionTracker.initAllocationTracker()

  if candidate.startBit > payloadBit:
    var prefix = inflateExactFromBoundary(owner.view, payloadBit, [],
      config.maxSpeculativeOutput, candidate.startBit, exactStop = true,
      tracker = addr result.resolutionTracker)
    if prefix.status != edsBoundary or prefix.endBit != candidate.startBit:
      prefix.release()
      owner.close()
      return nil
    if prefix.output.length > 0:
      let bytes = cast[ptr UncheckedArray[byte]](prefix.output.data)
      result.window = advanceWindow(result.window,
        bytes.toOpenArray(0, prefix.output.length - 1))
    result.account(prefix.output)
    result.pending.add(prefix.output)
    prefix.output = SharedBuffer()
    result.currentBit = candidate.startBit
  else:
    result.currentBit = candidate.startBit
  # Probe the first batch before spawning any worker: with no speculative
  # candidate beyond the authoritative position the batch would be a
  # single serial job, which the sequential zlib path decodes faster.
  let starts = result.collectBatchStarts()
  if starts.len < 2:
    result.releasePending()
    owner.close()
    return nil
  # Never spawn more workers than the first batch can keep busy.
  result.workers = min(result.workers, starts.len)
  result.firstBatchStarts = starts
  let queueCapacity = max(result.horizon * 2 + 2, 4)
  result.runtime = initMarkerRuntime(path, config, result.workers,
                                     queueCapacity, queueCapacity)

proc stopRuntime(decoder: MarkerPathDecoder; cancel: bool) =
  if decoder.runtime.isNil: return
  if cancel:
    decoder.runtime.cancelAndJoin()
  else:
    decoder.runtime.closeAdmission()
    decoder.runtime.joinWorkers()
  decoder.peakWorkers = max(decoder.peakWorkers,
                            decoder.runtime.workerStats().peak)
  decoder.peakBuffered = max(decoder.peakBuffered,
    uint64(max(decoder.runtime.allocations().peakBytes, 0)))
  decoder.runtime.deinit()
  decoder.runtime = nil

proc releasePending(decoder: MarkerPathDecoder) =
  for i in decoder.pendingIndex ..< decoder.pending.len:
    if not decoder.pending[i].data.isNil:
      decoder.pending[i].release(boWorker)
  decoder.pending.setLen(0)
  decoder.pendingIndex = 0
  decoder.pendingPos = 0

proc account(decoder: MarkerPathDecoder; buffer: SharedBuffer) =
  if decoder.config.outputLimit.isSome and
     uint64(buffer.length) > decoder.config.outputLimit.get -
                             min(decoder.totalOut,
                                 decoder.config.outputLimit.get):
    raise newGzFastError(geOutputLimit,
      "decoded output exceeds the configured outputLimit", decoder.currentBit shr 3)
  if buffer.length > 0:
    decoder.memberCrc = gzCrc32(decoder.memberCrc,
      cast[ptr byte](buffer.data), csize_t(buffer.length))
  decoder.memberBytes += uint64(buffer.length)
  decoder.totalOut += uint64(buffer.length)

proc addPending(decoder: MarkerPathDecoder; buffer: var SharedBuffer;
                currentOwner: BufferOwner) =
  decoder.account(buffer)
  if currentOwner != boWorker:
    if not buffer.transfer(currentOwner, boWorker):
      raise newGzFastError(geInternal, "invalid marker output ownership")
  decoder.pending.add(buffer)
  buffer = SharedBuffer()
  var live = 0'u64
  for i in decoder.pendingIndex ..< decoder.pending.len:
    live += uint64(decoder.pending[i].byteCapacity)
  decoder.peakBuffered = max(decoder.peakBuffered, live)

proc exactToStreamEnd(decoder: MarkerPathDecoder): bool =
  let remaining =
    if decoder.config.outputLimit.isSome:
      int(min(uint64(high(int)), decoder.config.outputLimit.get -
              min(decoder.totalOut, decoder.config.outputLimit.get)))
    else:
      decoder.config.maxSpeculativeOutput
  var exact =
    if decoder.window.length == 0:
      inflateExactFromBoundary(decoder.sourceOwner.view, decoder.currentBit,
        [], remaining, tracker = addr decoder.resolutionTracker)
    else:
      inflateExactFromBoundary(decoder.sourceOwner.view, decoder.currentBit,
        decoder.window.asOpenArray, remaining,
        tracker = addr decoder.resolutionTracker)
  if exact.status != edsStreamEnd:
    exact.release()
    return false
  decoder.currentBit = exact.endBit
  if exact.output.length > 0:
    let bytes = cast[ptr UncheckedArray[byte]](exact.output.data)
    decoder.window = advanceWindow(decoder.window,
      bytes.toOpenArray(0, exact.output.length - 1))
  decoder.addPending(exact.output, boWorker)
  true

proc startAuthoritativeReplay(decoder: MarkerPathDecoder) =
  ## Re-decode the member from its real gzip header, discard the already
  ## committed prefix, then expose only the unread suffix. This is bounded
  ## and remains the corruption oracle when speculative/exact work fails.
  var replay = openSequentialDecoder(decoder.path, decoder.config)
  var remaining = decoder.totalOut
  var scratch: array[64 * 1024, byte]
  while remaining > 0:
    let request = int(min(uint64(scratch.len), remaining))
    let count = replay.readData(addr scratch[0], request)
    if count == 0:
      replay.close()
      raise newGzFastError(geInternal,
        "authoritative replay ended before committed marker prefix")
    remaining -= uint64(count)
  decoder.fallback = replay
  decoder.hasFallback = true
  decoder.fallbackReplaysMember = true
  decoder.paths.incl(dpSequential)
  decoder.paths.incl(dpMixed)

proc verifyFooter(decoder: MarkerPathDecoder) =
  let footerOffset = (decoder.currentBit + 7) shr 3
  var bytes: array[8, byte]
  decoder.sourceOwner.view.readExactAt(footerOffset, addr bytes[0], 8)
  let parsed = parseGzipFooter(bytes)
  if parsed.crc32 != decoder.memberCrc:
    raise newGzFastError(geChecksumMismatch, "gzip member CRC32 mismatch",
                         footerOffset)
  if parsed.isize != uint32(decoder.memberBytes and 0xFFFF_FFFF'u64):
    raise newGzFastError(geSizeMismatch, "gzip member ISIZE mismatch",
                         footerOffset)
  inc decoder.memberCount
  let nextOffset = footerOffset + 8
  if nextOffset == decoder.sourceOwner.view.size:
    decoder.done = true
  else:
    decoder.fallback = openSequentialDecoderAt(decoder.path, nextOffset,
                                                decoder.config)
    decoder.hasFallback = true
    decoder.paths.incl(dpSequential)
    decoder.paths.incl(dpMixed)

proc prepareResolutionJob(decoder: MarkerPathDecoder;
                          incoming: var JobResult; expectedEnd: uint64;
                          terminal: bool; ordinal: uint64;
                          tracker: ptr AllocationTracker;
                          job: var DecodeJob;
                          nextWindow: var ResolvedWindow): bool =
  if incoming.status != jrsOk or incoming.startBit != decoder.currentBit or
     (not terminal and incoming.endBit != expectedEnd):
    if not incoming.output.data.isNil: incoming.output.release(boCoordinator)
    return false
  var marked = MarkerBuffer(storage: incoming.output,
    count: int(incoming.decodedLength), markerCount: incoming.markerCount)
  incoming.output = SharedBuffer()
  if windowAfter(decoder.window, marked, nextWindow) != mrsOk:
    marked.release(boCoordinator)
    return false
  var windowInput: SharedBuffer
  if decoder.window.length > 0:
    windowInput = allocSharedBuffer(decoder.window.length, owner = boWorker,
                                    tracker = tracker)
    copyMem(windowInput.data,
      unsafeAddr decoder.window.bytes[DeflateWindowSize - decoder.window.length],
      decoder.window.length)
    windowInput.setLength(decoder.window.length)
  if not marked.storage.transfer(boCoordinator, boWorker):
    if not windowInput.data.isNil: windowInput.release(boWorker)
    marked.release()
    return false
  job = DecodeJob(ordinal: ordinal, kind: jkResolveMarkers,
    markerInput: marked.storage, symbolCount: marked.count,
    sourceMarkerCount: marked.markerCount,
    windowInput: windowInput, startBit: incoming.startBit,
    stopBit: incoming.endBit,
    outputTracker: addr decoder.resolutionTracker)
  marked.storage = SharedBuffer()
  true

proc prepareBatch(decoder: MarkerPathDecoder) =
  if decoder.done or decoder.hasFallback or
     decoder.pendingIndex < decoder.pending.len:
    return
  decoder.pending.setLen(0)
  decoder.pendingIndex = 0
  decoder.pendingPos = 0

  var starts: seq[uint64]
  if decoder.firstBatchStarts.len > 0:
    # Candidates probed at open time; the position has not moved since.
    starts = decoder.firstBatchStarts
    decoder.firstBatchStarts = @[]
  else:
    starts = decoder.collectBatchStarts()

  let terminal = starts.len == 1
  let jobCount = if terminal: 1 else: starts.len - 1
  let runtime = decoder.runtime
  let ordinalBase = decoder.nextOrdinal
  decoder.nextOrdinal += uint64(jobCount * 2)
  block processBatch:
    for i in 0 ..< jobCount:
      let stop = if i + 1 < starts.len: starts[i + 1] else: high(uint64)
      let job = DecodeJob(ordinal: ordinalBase + uint64(i * 2),
        kind: jkDecodeBoundary,
        startBit: starts[i], stopBit: stop,
        compressedStart: starts[i] shr 3)
      if runtime.submit(job) != qsOk:
        raise newGzFastError(geInternal, "failed to schedule marker job")
    for i in 0 ..< jobCount:
      var decoded: JobResult
      if runtime.nextOrdered(decoded) != rnsOk:
        decoder.stopRuntime(cancel = true)
        if not decoder.exactToStreamEnd():
          decoder.startAuthoritativeReplay()
        else:
          decoder.verifyFooter()
        break
      let expectedEnd = if i + 1 < starts.len: starts[i + 1] else: 0
      let isTerminal = terminal and i == jobCount - 1
      let streamEnd = decoded.streamEnd
      let handoffReady = decoded.handoffReady
      let decodedEnd = decoded.endBit
      var resolutionJob: DecodeJob
      var nextWindow: ResolvedWindow
      if not decoder.prepareResolutionJob(decoded, expectedEnd, isTerminal,
          ordinalBase + uint64(i * 2 + 1), addr runtime.tracker,
          resolutionJob, nextWindow) or
         runtime.submit(resolutionJob) != qsOk:
        if not resolutionJob.markerInput.data.isNil:
          resolutionJob.markerInput.release()
        if not resolutionJob.windowInput.data.isNil:
          resolutionJob.windowInput.release()
        decoder.stopRuntime(cancel = true)
        if not decoder.exactToStreamEnd():
          decoder.startAuthoritativeReplay()
        else:
          decoder.paths.incl(dpSequential)
          decoder.paths.incl(dpMixed)
          decoder.verifyFooter()
        break
      var resolved: JobResult
      if runtime.nextOrdered(resolved) != rnsOk or resolved.status != jrsOk:
        if not resolved.output.data.isNil: resolved.output.release(boCoordinator)
        decoder.stopRuntime(cancel = true)
        if not decoder.exactToStreamEnd(): decoder.startAuthoritativeReplay()
        else:
          decoder.paths.incl(dpSequential); decoder.paths.incl(dpMixed)
          decoder.verifyFooter()
        break
      decoder.window = nextWindow
      decoder.currentBit = decodedEnd
      decoder.addPending(resolved.output, boCoordinator)
      if streamEnd:
        decoder.stopRuntime(cancel = false)
        decoder.verifyFooter()
        break
      if handoffReady:
        decoder.stopRuntime(cancel = false)
        if not decoder.exactToStreamEnd(): decoder.startAuthoritativeReplay()
        else: decoder.verifyFooter()
        break
  decoder.peakBuffered = max(decoder.peakBuffered,
    uint64(max(decoder.resolutionTracker.snapshot().peakBytes, 0)))

proc readData*(decoder: MarkerPathDecoder; destination: pointer;
               length: int): int =
  if length <= 0: return 0
  var target = destination
  while result < length:
    if decoder.pendingIndex < decoder.pending.len:
      var buffer = addr decoder.pending[decoder.pendingIndex]
      let available = buffer.length - decoder.pendingPos
      let count = min(length - result, available)
      copyMem(target, cast[pointer](cast[uint](buffer.data) +
                                   uint(decoder.pendingPos)), count)
      decoder.pendingPos += count
      result += count
      target = cast[pointer](cast[uint](target) + uint(count))
      if decoder.pendingPos == buffer.length:
        buffer[].release(boWorker)
        inc decoder.pendingIndex
        decoder.pendingPos = 0
      continue
    if decoder.hasFallback:
      return result + decoder.fallback.readData(target, length - result)
    if decoder.done: break
    decoder.prepareBatch()

proc atEnd*(decoder: MarkerPathDecoder): bool =
  if decoder.hasFallback: return decoder.fallback.atEnd()
  if decoder.pendingIndex < decoder.pending.len: return false
  if not decoder.done: decoder.prepareBatch()
  decoder.done and decoder.pendingIndex >= decoder.pending.len

proc verifyRemaining*(decoder: MarkerPathDecoder) =
  while true:
    while decoder.pendingIndex < decoder.pending.len:
      if not decoder.pending[decoder.pendingIndex].data.isNil:
        decoder.pending[decoder.pendingIndex].release(boWorker)
      inc decoder.pendingIndex
    decoder.pendingPos = 0
    if decoder.hasFallback:
      decoder.fallback.verifyRemaining()
      return
    if decoder.done: return
    decoder.prepareBatch()

proc close*(decoder: MarkerPathDecoder) =
  if decoder.isNil or decoder.closed: return
  decoder.closed = true
  decoder.stopRuntime(cancel = true)
  decoder.releasePending()
  if decoder.hasFallback: decoder.fallback.close()
  decoder.sourceOwner.close()

proc report*(decoder: MarkerPathDecoder): DecodeReport =
  if decoder.hasFallback:
    let tail = decoder.fallback.report()
    DecodeReport(compressedBytes: tail.compressedBytes,
      decompressedBytes:
        if decoder.fallbackReplaysMember: tail.decompressedBytes
        else: decoder.totalOut + tail.decompressedBytes,
      memberCount:
        if decoder.fallbackReplaysMember: tail.memberCount
        else: decoder.memberCount + tail.memberCount,
      pathsUsed: decoder.paths, crcVerified: tail.crcVerified,
      peakWorkers: max(decoder.peakWorkers, tail.peakWorkers),
      peakBufferedBytes: max(decoder.peakBuffered, tail.peakBufferedBytes))
  else:
    DecodeReport(compressedBytes: decoder.sourceOwner.view.size,
      decompressedBytes: decoder.totalOut, memberCount: decoder.memberCount,
      pathsUsed: decoder.paths, crcVerified: decoder.done,
      peakWorkers: decoder.peakWorkers,
      peakBufferedBytes: decoder.peakBuffered)

proc statsSnapshot*(decoder: MarkerPathDecoder): DecoderStats =
  if decoder.hasFallback:
    let tail = decoder.fallback.statsSnapshot()
    DecoderStats(compressedBytes: tail.compressedBytes,
      decompressedBytes:
        if decoder.fallbackReplaysMember: tail.decompressedBytes
        else: decoder.totalOut + tail.decompressedBytes,
      memberCount:
        if decoder.fallbackReplaysMember: tail.memberCount
        else: decoder.memberCount + tail.memberCount,
      activeWorkers: tail.activeWorkers,
      bufferedBytes: tail.bufferedBytes,
      finished: tail.finished)
  else:
    DecoderStats(compressedBytes: decoder.currentBit shr 3,
      decompressedBytes: decoder.totalOut, memberCount: decoder.memberCount,
      activeWorkers: 0,
      bufferedBytes: if decoder.pendingIndex < decoder.pending.len:
        uint64(decoder.pending[decoder.pendingIndex].length - decoder.pendingPos)
      else: 0,
      finished: decoder.done)

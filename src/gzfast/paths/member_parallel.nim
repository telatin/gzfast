## Streaming parallel decoder for independent gzip members (BGZF and
## densely concatenated ordinary gzip). Ordinary single-member gzip
## remains on the sequential/marker paths.

import std/[cpuinfo, options]
import ../buffers, ../config, ../errors, ../report, ../source
import ../gzip/[bgzf, members]
import ../scheduler/[bounded_queue, controller, jobs]
import ../scheduler/adaptive
import ./bgzf as bgzfPath
import ./multimember
import ./sequential

type
  ParallelMemberMode = enum
    pmmBgzf
    pmmMultiMember

  ParallelMemberDecoder* = ref object
    path: string
    config: GzFastConfig
    runtime: MemberRuntime
    mode: ParallelMemberMode
    horizon: int
    nextScheduleOffset: uint64
    nextOrdinal: uint64
    nextMemberIndex: uint64
    expectedStart: uint64
    inFlight: int
    batchActive: bool
    planningDone: bool
    chainBroken: bool
    fallbackOffset: uint64
    current: JobResult
    currentPos: int
    parallelBytes: uint64
    parallelMembers: uint64
    runtimePeakBytes: uint64
    runtimePeakWorkers: int
    fallback: SequentialDecoder
    hasFallback: bool
    done: bool
    closed: bool

proc resolvedRuntime(config: GzFastConfig): tuple[workers, horizon: int] =
  var workers = if config.threads > 0: config.threads
                else: initialWorkerTarget(min(max(countProcessors(), 1), 16))
  var horizon = if config.inFlightChunks > 0: config.inFlightChunks
                else: workers + 2
  let memoryCeiling = if config.memoryLimit > 0: config.memoryLimit
                      else: 512'i64 * 1024 * 1024
  proc estimate(): int64 =
    int64(workers) * int64(config.inputPageSize) +
      int64(horizon) * int64(config.maxSpeculativeOutput) +
      int64(workers) * 256 * 1024
  while horizon > 1 and estimate() > memoryCeiling:
    dec horizon
  while workers > 1 and estimate() > memoryCeiling:
    dec workers
    horizon = min(horizon, workers + 2)
  if estimate() > memoryCeiling:
    return (0, 0)
  (workers, max(horizon, 1))

proc scanEnd(decoder: ParallelMemberDecoder; start: uint64): uint64 =
  let grid = uint64(decoder.config.compressedGridSize)
  let count = uint64(decoder.horizon)
  let span = if count != 0 and grid > high(uint64) div count:
               high(uint64)
             else:
               grid * count
  if span > decoder.runtime.source.size - start:
    decoder.runtime.source.size
  else:
    start + span

proc tryOpenParallelMemberDecoder*(path: string;
                                   config: GzFastConfig): ParallelMemberDecoder =
  ## Return nil when no safe independent-member path is visible.
  if config.threads == 1:
    return nil
  let sizing = resolvedRuntime(config)
  if sizing.workers == 0:
    return nil
  let owner = openReadAtSource(path)
  let source = owner.view
  if source.size == 0:
    owner.close()
    return nil

  let firstBgzf = source.inspectBgzfLink(0, config.maxHeaderSize)
  var mode: ParallelMemberMode
  if firstBgzf.status == blsOk:
    mode = pmmBgzf
  else:
    let probeSpan = min(source.size,
      uint64(config.compressedGridSize) * uint64(sizing.horizon))
    let candidates = source.scanHeaderCandidates(0, probeSpan,
      config.maxHeaderSize, sizing.horizon)
    if candidates.len < 2 or candidates[0] != 0:
      owner.close()
      return nil
    # Thousands of tiny members are faster through the authoritative loop
    # until ordinary-member grouping exists; avoid per-member queue/thread
    # overhead when the bounded probe is both dense and sub-256-byte.
    if candidates.len >= min(sizing.horizon, 8):
      let averageSpacing = (candidates[^1] - candidates[0]) div
                           uint64(candidates.len - 1)
      if averageSpacing < 256:
        owner.close()
        return nil
    mode = pmmMultiMember

  try:
    let runtime = initMemberRuntime(owner, config, sizing.workers,
                                    sizing.horizon, sizing.horizon)
    result = ParallelMemberDecoder(
      path: path, config: config, runtime: runtime, mode: mode,
      horizon: sizing.horizon
    )
  except CatchableError:
    owner.close()
    raise

proc rememberRuntimePeaks(decoder: ParallelMemberDecoder) =
  if decoder.runtime.isNil:
    return
  let allocations = decoder.runtime.allocations()
  decoder.runtimePeakBytes = max(decoder.runtimePeakBytes,
                                 uint64(max(allocations.peakBytes, 0)))
  decoder.runtimePeakWorkers = max(decoder.runtimePeakWorkers,
                                   decoder.runtime.workerStats().peak)

proc stopRuntime(decoder: ParallelMemberDecoder; cancel: bool) =
  if decoder.runtime.isNil:
    return
  if cancel:
    decoder.runtime.cancelAndJoin()
  else:
    decoder.runtime.joinWorkers()
  decoder.rememberRuntimePeaks()
  decoder.runtime.deinit()

proc startFallback(decoder: ParallelMemberDecoder; offset: uint64) =
  decoder.stopRuntime(cancel = true)
  if offset >= decoder.runtime.source.size:
    decoder.done = true
    return
  var fallbackConfig = decoder.config
  if fallbackConfig.outputLimit.isSome:
    let limit = fallbackConfig.outputLimit.get
    fallbackConfig.outputLimit = some(
      if decoder.parallelBytes >= limit: 0'u64
      else: limit - decoder.parallelBytes)
  decoder.fallback = openSequentialDecoderAt(decoder.path, offset,
                                              fallbackConfig)
  decoder.hasFallback = true

proc scheduleBgzf(decoder: ParallelMemberDecoder) =
  const blocksPerJob = 8
  while not decoder.planningDone and decoder.inFlight < decoder.horizon:
    if decoder.nextScheduleOffset == decoder.runtime.source.size:
      decoder.planningDone = true
      decoder.runtime.closeAdmission()
      break
    var planned = bgzfPath.planBgzfJob(decoder.runtime.source,
      decoder.nextScheduleOffset, decoder.nextOrdinal,
      decoder.config.maxHeaderSize)
    if planned.status != blsOk:
      decoder.planningDone = true
      decoder.chainBroken = true
      decoder.fallbackOffset = decoder.nextScheduleOffset
      decoder.runtime.closeAdmission()
      break
    planned.job.memberIndex = decoder.nextMemberIndex
    var grouped = 1
    var groupEnd = planned.job.knownEnd
    while grouped < blocksPerJob and groupEnd < decoder.runtime.source.size:
      let next = bgzfPath.planBgzfJob(decoder.runtime.source, groupEnd,
        decoder.nextOrdinal, decoder.config.maxHeaderSize)
      if next.status != blsOk: break
      groupEnd = next.job.knownEnd
      inc grouped
    planned.job.knownEnd = groupEnd
    planned.job.compressedEnd = groupEnd
    if decoder.runtime.submit(planned.job) != qsOk:
      raise newGzFastError(geInternal, "failed to schedule BGZF block",
                           decoder.nextScheduleOffset)
    decoder.nextScheduleOffset = groupEnd
    decoder.nextMemberIndex += uint64(grouped)
    inc decoder.nextOrdinal
    inc decoder.inFlight

proc scheduleMemberBatch(decoder: ParallelMemberDecoder) =
  if decoder.expectedStart >= decoder.runtime.source.size:
    decoder.planningDone = true
    decoder.runtime.closeAdmission()
    return
  let jobs = planMemberBatch(decoder.runtime.source,
    decoder.expectedStart, decoder.scanEnd(decoder.expectedStart),
    decoder.config.maxHeaderSize, decoder.horizon, decoder.nextOrdinal)
  if jobs.len == 0 or jobs[0].compressedStart != decoder.expectedStart:
    decoder.planningDone = true
    decoder.chainBroken = true
    decoder.fallbackOffset = decoder.expectedStart
    decoder.runtime.closeAdmission()
    return
  for job in jobs:
    if decoder.runtime.submit(job) != qsOk:
      raise newGzFastError(geInternal, "failed to schedule member candidate",
                           job.compressedStart)
    inc decoder.inFlight
    inc decoder.nextOrdinal
  decoder.batchActive = true

proc raiseWorkerError(result: JobResult) =
  let offset = result.error.compressedOffset
  let memberIndex = result.error.memberIndex
  case result.error.kind
  of weInvalidHeader:
    raise newGzFastError(geInvalidHeader, "invalid gzip member header", offset,
                         memberIndex)
  of weInvalidDeflate:
    raise newGzFastError(geInvalidDeflate, "invalid DEFLATE member", offset,
                         memberIndex)
  of weTruncated:
    raise newGzFastError(geTruncatedInput, "truncated gzip member", offset,
                         memberIndex)
  of weChecksum:
    raise newGzFastError(geChecksumMismatch, "gzip member CRC32 mismatch", offset,
                         memberIndex)
  of weSize:
    raise newGzFastError(geSizeMismatch, "gzip member ISIZE mismatch", offset,
                         memberIndex)
  of weCancelled:
    raise newGzFastError(geCancelled, "parallel member decoding cancelled", offset,
                         memberIndex)
  else:
    raise newGzFastError(geInternal, "parallel member worker failure", offset,
                         memberIndex)

proc acceptResult(decoder: ParallelMemberDecoder;
                  incoming: var JobResult): bool =
  if incoming.status == jrsError:
    if incoming.compressedStart == decoder.expectedStart:
      if decoder.mode != pmmBgzf:
        incoming.error.memberIndex = decoder.parallelMembers
      incoming.raiseWorkerError()
    if not incoming.output.data.isNil:
      incoming.output.release(boCoordinator)
    return false # speculative failure is rejection, not file corruption
  if incoming.status != jrsOk:
    if incoming.compressedStart >= decoder.expectedStart:
      decoder.chainBroken = true
      decoder.fallbackOffset = decoder.expectedStart
    if not incoming.output.data.isNil:
      incoming.output.release(boCoordinator)
    return false
  if incoming.compressedStart < decoder.expectedStart:
    incoming.output.release(boCoordinator)
    return false # plausible header inside authoritative payload
  if incoming.compressedStart > decoder.expectedStart:
    incoming.output.release(boCoordinator)
    decoder.chainBroken = true
    decoder.fallbackOffset = decoder.expectedStart
    return false
  if decoder.config.outputLimit.isSome and
     incoming.decodedLength > decoder.config.outputLimit.get -
                            min(decoder.parallelBytes,
                                decoder.config.outputLimit.get):
    incoming.output.release(boCoordinator)
    raise newGzFastError(geOutputLimit,
      "decoded output exceeds the configured outputLimit",
      incoming.compressedStart)
  decoder.expectedStart = incoming.memberEnd
  decoder.parallelBytes += incoming.decodedLength
  decoder.parallelMembers += uint64(max(incoming.verifiedMembers, 1))
  decoder.current = incoming
  incoming = JobResult()
  decoder.currentPos = 0
  true

proc prepareNext(decoder: ParallelMemberDecoder) =
  while decoder.current.output.data.isNil and not decoder.done and
        not decoder.hasFallback:
    if decoder.mode == pmmBgzf:
      decoder.scheduleBgzf()
    elif decoder.inFlight == 0 and not decoder.planningDone:
      decoder.batchActive = false
      decoder.scheduleMemberBatch()

    if decoder.inFlight == 0:
      if decoder.chainBroken:
        decoder.startFallback(decoder.fallbackOffset)
      elif decoder.planningDone or decoder.expectedStart ==
           decoder.runtime.source.size:
        decoder.stopRuntime(cancel = false)
        decoder.done = true
      continue

    var result: JobResult
    case decoder.runtime.nextOrdered(result)
    of rnsOk:
      dec decoder.inFlight
      discard decoder.acceptResult(result)
      if decoder.current.output.data.isNil and decoder.parallelMembers > 0 and
         decoder.expectedStart == decoder.runtime.source.size:
        decoder.planningDone = true
        decoder.runtime.closeAdmission()
    of rnsCancelled:
      raise newGzFastError(geCancelled, "parallel member decoding cancelled",
                           decoder.expectedStart)
    else:
      raise newGzFastError(geInternal, "parallel member result queue closed",
                           decoder.expectedStart)

    # A zero-output member is still verified and counted but needs no handoff.
    if not decoder.current.output.data.isNil and decoder.current.output.length == 0:
      decoder.current.output.release(boCoordinator)
      decoder.current = JobResult()

proc readData*(decoder: ParallelMemberDecoder; buffer: pointer;
               length: int): int =
  if length <= 0:
    return 0
  if decoder.closed:
    raise newException(IOError, "gzfast: parallel decoder is closed")
  if decoder.hasFallback:
    return decoder.fallback.readData(buffer, length)
  
  # Loop to fill the buffer as much as possible across member boundaries.
  # This ensures readAll() only sees partial reads when truly at EOF.
  var totalRead = 0
  var destPtr = buffer
  
  while totalRead < length:
    decoder.prepareNext()
    if decoder.hasFallback:
      # Switched to fallback mid-stream; let it handle the rest
      let fallbackRead = decoder.fallback.readData(destPtr, length - totalRead)
      return totalRead + fallbackRead
    if decoder.done:
      break
    
    let available = decoder.current.output.length - decoder.currentPos
    let toRead = min(length - totalRead, available)
    if toRead == 0:
      break
    
    copyMem(destPtr, cast[pointer](cast[uint](decoder.current.output.data) +
                                   uint(decoder.currentPos)), toRead)
    decoder.currentPos += toRead
    totalRead += toRead
    destPtr = cast[pointer](cast[uint](destPtr) + uint(toRead))
    
    if decoder.currentPos == decoder.current.output.length:
      decoder.current.output.release(boCoordinator)
      decoder.current = JobResult()
  
  result = totalRead

proc atEnd*(decoder: ParallelMemberDecoder): bool =
  if decoder.hasFallback:
    return decoder.fallback.atEnd()
  decoder.prepareNext()
  if decoder.hasFallback:
    decoder.fallback.atEnd()
  else:
    decoder.done and decoder.current.output.data.isNil

proc verifyRemaining*(decoder: ParallelMemberDecoder) =
  while true:
    if not decoder.current.output.data.isNil:
      decoder.current.output.release(boCoordinator)
      decoder.current = JobResult()
    if decoder.hasFallback:
      decoder.fallback.verifyRemaining()
      return
    if decoder.done: return
    decoder.prepareNext()

proc close*(decoder: ParallelMemberDecoder) =
  if decoder.isNil or decoder.closed:
    return
  decoder.closed = true
  if not decoder.current.output.data.isNil:
    decoder.current.output.release(boCoordinator)
  if not decoder.runtime.isNil:
    decoder.stopRuntime(cancel = true)
  if decoder.hasFallback:
    decoder.fallback.close()

proc report*(decoder: ParallelMemberDecoder): DecodeReport =
  let parallelPath = if decoder.mode == pmmBgzf: dpBgzf else: dpMultiMember
  if decoder.hasFallback:
    let fallbackReport = decoder.fallback.report()
    DecodeReport(
      compressedBytes: fallbackReport.compressedBytes,
      decompressedBytes: decoder.parallelBytes +
                         fallbackReport.decompressedBytes,
      memberCount: decoder.parallelMembers + fallbackReport.memberCount,
      pathsUsed: {parallelPath, dpSequential, dpMixed},
      crcVerified: fallbackReport.crcVerified,
      peakWorkers: max(decoder.runtimePeakWorkers,
                       fallbackReport.peakWorkers),
      peakBufferedBytes: max(decoder.runtimePeakBytes,
                             fallbackReport.peakBufferedBytes)
    )
  else:
    DecodeReport(
      compressedBytes: if decoder.done: decoder.expectedStart
                       else: decoder.nextScheduleOffset,
      decompressedBytes: decoder.parallelBytes,
      memberCount: decoder.parallelMembers,
      pathsUsed: {parallelPath},
      crcVerified: decoder.done,
      peakWorkers: decoder.runtimePeakWorkers,
      peakBufferedBytes: decoder.runtimePeakBytes
    )

proc statsSnapshot*(decoder: ParallelMemberDecoder): DecoderStats =
  if decoder.hasFallback:
    let fallbackStats = decoder.fallback.statsSnapshot()
    DecoderStats(
      compressedBytes: fallbackStats.compressedBytes,
      decompressedBytes: decoder.parallelBytes + fallbackStats.decompressedBytes,
      memberCount: decoder.parallelMembers + fallbackStats.memberCount,
      activeWorkers: fallbackStats.activeWorkers,
      bufferedBytes: fallbackStats.bufferedBytes,
      finished: fallbackStats.finished
    )
  else:
    DecoderStats(
      compressedBytes: decoder.expectedStart,
      decompressedBytes: decoder.parallelBytes,
      memberCount: decoder.parallelMembers,
      activeWorkers: if decoder.runtime.isNil: 0
                     else: decoder.runtime.workerStats().active,
      bufferedBytes: uint64(max(decoder.current.output.length -
                                decoder.currentPos, 0)),
      finished: decoder.done
    )

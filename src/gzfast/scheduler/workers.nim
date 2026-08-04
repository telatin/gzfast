## Fixed persistent worker pool over bounded job/result queues.

import std/[atomics, os, typedthreads]
import ../buffers
import ../errors
import ../source
import ../gzip/[footer, members]
import ../deflate/marker_decode
import ../deflate/bitreader
import ../deflate/marker_resolve
import ../private/zlib_api
import ./bounded_queue, ./jobs

type
  WorkerMode = enum
    wmSynthetic
    wmMembers
    wmMarkers

  WorkerPoolStats* = object
    active: Atomic[int]
    peak: Atomic[int]
    started: Atomic[uint64]
    completed: Atomic[uint64]

  WorkerStatsSnapshot* = object
    active*: int
    peak*: int
    started*: uint64
    completed*: uint64

  WorkerThreadArg = object
    jobs: ptr BoundedQueue[DecodeJob]
    results: ptr BoundedQueue[JobResult]
    cancellation: ptr CancellationToken
    tracker: ptr AllocationTracker
    stats: ptr WorkerPoolStats
    mode: WorkerMode
    source: ReadAtSource
    inputPageSize: int
    maxHeaderSize: int
    maxMemberOutput: int

  WorkerPool* = object
    threads: seq[Thread[WorkerThreadArg]]
    stats: WorkerPoolStats
    started: bool
    joined: bool

proc updatePeak(stats: ptr WorkerPoolStats; active: int) =
  while true:
    let oldPeak = stats.peak.load(moRelaxed)
    if active <= oldPeak:
      return
    var expected = oldPeak
    if stats.peak.compareExchange(expected, active, moRelaxed, moRelaxed):
      return

proc failedMember(job: DecodeJob; kind: WorkerErrorKind;
                  offset: uint64; detail = 0'i32): JobResult =
  result = JobResult(
    ordinal: job.ordinal,
    generation: job.generation,
    compressedStart: job.compressedStart,
    compressedEnd: job.compressedEnd,
    status: if job.authoritative and kind != weOutputCap: jrsError
            else: jrsRejected
  )
  result.error = WorkerErrorRecord(kind: kind,
    compressedOffset: offset, memberIndex: job.memberIndex,
    detailCode: detail)

proc processMember(job: DecodeJob; arg: WorkerThreadArg;
                   inflater: GzInflaterHandle;
                   inputPage: var SharedBuffer): JobResult =
  result = JobResult(
    ordinal: job.ordinal,
    generation: job.generation,
    compressedStart: job.compressedStart,
    compressedEnd: job.compressedEnd,
    status: jrsOk
  )
  if job.kind notin {jkDecodeMember, jkDecodeBgzfGroup} or
     inflater.isNil or inputPage.data.isNil:
    return failedMember(job, weInvalidJob, job.compressedStart)

  let parsed = arg.source.parseHeaderAt(job.compressedStart,
                                         arg.maxHeaderSize)
  case parsed.status
  of hasOk:
    discard
  of hasTruncated:
    return failedMember(job, weTruncated, parsed.errorOffset)
  of hasInvalid, hasTooLarge:
    return failedMember(job, weInvalidHeader, parsed.errorOffset)

  if job.kind == jkDecodeBgzfGroup:
    if parsed.info.bgzfBlockSize <= 0 or job.knownEnd == 0 or
       job.compressedStart + uint64(parsed.info.bgzfBlockSize) != job.knownEnd:
      return failedMember(job, weInvalidHeader, job.compressedStart)

  if gzInflaterReset(inflater) != gzOk:
    return failedMember(job, weInternal, parsed.payloadOffset)

  let upper = if job.knownEnd != 0: min(job.knownEnd, arg.source.size)
              else: arg.source.size
  var nextReadOffset = parsed.payloadOffset
  var pageBase = parsed.payloadOffset
  var pagePos, pageLen: int
  var crc = 0'u32
  let initialCapacity = min(arg.maxMemberOutput,
                            max(4096, min(64 * 1024,
                                          arg.maxMemberOutput)))
  if initialCapacity <= 0:
    return failedMember(job, weOutputCap, parsed.payloadOffset)
  result.output = allocSharedBuffer(initialCapacity, owner = boWorker,
                                    tracker = arg.tracker)

  while true:
    if arg.cancellation[].isCancelled():
      result.output.release(boWorker)
      return failedMember(job, weCancelled, pageBase + uint64(pagePos))
    if pagePos == pageLen:
      if nextReadOffset >= upper:
        result.output.release(boWorker)
        return failedMember(job, weTruncated, nextReadOffset)
      let request = int(min(uint64(inputPage.capacity),
                            upper - nextReadOffset))
      pageBase = nextReadOffset
      pageLen = arg.source.readAt(nextReadOffset, inputPage.data, request)
      pagePos = 0
      if pageLen == 0:
        result.output.release(boWorker)
        return failedMember(job, weTruncated, nextReadOffset)
      nextReadOffset += uint64(pageLen)

    if result.output.length == result.output.capacity:
      if result.output.capacity >= arg.maxMemberOutput:
        result.output.release(boWorker)
        return failedMember(job, weOutputCap, pageBase + uint64(pagePos))
      result.output.reserve(result.output.length + 1,
                            arg.maxMemberOutput)

    var inPtr = inputPage.byteAt(pagePos)
    var inLen = csize_t(pageLen - pagePos)
    let inBefore = inLen
    var outPtr = result.output.byteAt(result.output.length)
    var outLen = csize_t(result.output.capacity - result.output.length)
    let outBefore = outLen
    let status = gzInflaterStep(inflater, addr inPtr, addr inLen,
                                addr outPtr, addr outLen, gzNoFlush)
    let consumed = int(inBefore - inLen)
    let produced = int(outBefore - outLen)
    pagePos += consumed
    if produced > 0:
      crc = gzCrc32(crc, result.output.byteAt(result.output.length),
                    csize_t(produced))
      result.output.setLength(result.output.length + produced)

    case status
    of gzStreamEnd:
      break
    of gzOk, gzBufError:
      if consumed == 0 and produced == 0 and pagePos < pageLen:
        result.output.release(boWorker)
        return failedMember(job, weInvalidDeflate,
                            pageBase + uint64(pagePos), int32(status))
    of gzDataError:
      result.output.release(boWorker)
      return failedMember(job, weInvalidDeflate,
                          pageBase + uint64(pagePos), int32(status))
    else:
      result.output.release(boWorker)
      return failedMember(job, weInternal,
                          pageBase + uint64(pagePos), int32(status))

  let footerOffset = pageBase + uint64(pagePos)
  var footerBytes: array[8, byte]
  try:
    arg.source.readExactAt(footerOffset, addr footerBytes[0], footerBytes.len)
  except CatchableError:
    result.output.release(boWorker)
    return failedMember(job, weTruncated, footerOffset)
  let memberFooter = parseGzipFooter(footerBytes)
  let memberEnd = footerOffset + 8
  if memberFooter.crc32 != crc:
    result.output.release(boWorker)
    return failedMember(job, weChecksum, footerOffset)
  if memberFooter.isize != uint32(uint64(result.output.length) and
                                  0xFFFF_FFFF'u64):
    result.output.release(boWorker)
    return failedMember(job, weSize, footerOffset)
  if job.knownEnd != 0 and memberEnd != job.knownEnd:
    result.output.release(boWorker)
    return failedMember(job, weInvalidDeflate, memberEnd)

  result.decodedLength = uint64(result.output.length)
  result.memberEnd = memberEnd
  result.outputCrc32 = crc
  result.storedCrc32 = memberFooter.crc32
  result.storedIsize = memberFooter.isize

proc processBgzfGroup(job: DecodeJob; arg: WorkerThreadArg;
                      inflater: GzInflaterHandle;
                      inputPage: var SharedBuffer): JobResult =
  result = JobResult(ordinal: job.ordinal, generation: job.generation,
    compressedStart: job.compressedStart, compressedEnd: job.compressedEnd,
    status: jrsOk, memberEnd: job.knownEnd)
  var offset = job.compressedStart
  var memberIndex = job.memberIndex
  result.output = allocSharedBuffer(4096, owner = boWorker,
                                    tracker = arg.tracker)
  while offset < job.knownEnd:
    let header = arg.source.parseHeaderAt(offset, arg.maxHeaderSize)
    if header.status != hasOk or header.info.bgzfBlockSize <= 0:
      result.output.release(boWorker)
      return failedMember(job, weInvalidHeader, offset)
    let blockEnd = offset + uint64(header.info.bgzfBlockSize)
    if blockEnd > job.knownEnd:
      result.output.release(boWorker)
      return failedMember(job, weInvalidHeader, offset)
    var blockJob = DecodeJob(ordinal: job.ordinal,
      kind: jkDecodeBgzfGroup, compressedStart: offset,
      compressedEnd: blockEnd, knownEnd: blockEnd,
      authoritative: true, memberIndex: memberIndex)
    var blockResult = processMember(blockJob, arg, inflater, inputPage)
    if blockResult.status != jrsOk:
      result.output.release(boWorker)
      blockResult.ordinal = job.ordinal
      # The group is the ordered authoritative unit; keep the exact failing
      # block in error.offset/memberIndex, but compare group start for commit.
      blockResult.compressedStart = job.compressedStart
      blockResult.compressedEnd = job.compressedEnd
      return blockResult
    let needed = result.output.length + blockResult.output.length
    if needed > arg.maxMemberOutput:
      blockResult.output.release(boWorker)
      result.output.release(boWorker)
      return failedMember(job, weOutputCap, offset)
    result.output.reserve(needed, arg.maxMemberOutput)
    if blockResult.output.length > 0:
      copyMem(result.output.byteAt(result.output.length), blockResult.output.data,
              blockResult.output.length)
    result.output.setLength(needed)
    result.decodedLength += blockResult.decodedLength
    blockResult.output.release(boWorker)
    inc result.verifiedMembers
    inc memberIndex
    offset = blockEnd

proc processSynthetic(job: DecodeJob; arg: WorkerThreadArg): JobResult =
  result = JobResult(
    ordinal: job.ordinal,
    generation: job.generation,
    compressedStart: job.compressedStart,
    compressedEnd: job.compressedEnd,
    status: jrsOk
  )
  if job.kind != jkDecodeBoundary or job.outputLength < 0:
    result.status = jrsError
    result.error.kind = weInvalidJob
    result.error.compressedOffset = job.compressedStart
    return
  result.output = allocSharedBuffer(job.outputLength,
    owner = boWorker, tracker = arg.tracker)
  if job.outputLength > 0:
    let bytes = cast[ptr UncheckedArray[byte]](result.output.data)
    for i in 0 ..< job.outputLength:
      bytes[i] = job.payloadByte
    result.output.setLength(job.outputLength)
  result.decodedLength = uint64(job.outputLength)

proc processMarker(job: DecodeJob; arg: WorkerThreadArg;
                   workspace: MarkerDecoderWorkspace): JobResult =
  result = JobResult(
    ordinal: job.ordinal,
    generation: job.generation,
    compressedStart: job.compressedStart,
    compressedEnd: job.compressedEnd,
    startBit: job.startBit,
    status: jrsOk
  )
  if job.kind != jkDecodeBoundary or workspace.isNil:
    result.status = jrsError
    result.error.kind = weInvalidJob
    return
  var decoded = decodeMarkerChunk(arg.source, job.startBit, job.stopBit,
    arg.maxMemberOutput, workspace, arg.tracker,
    min(arg.inputPageSize, BitReaderPageCapacity))
  result.endBit = decoded.endBit
  result.markerCount = decoded.output.markerCount
  result.markerStatus = int32(ord(decoded.status))
  result.streamEnd = decoded.status == mdsStreamEnd
  result.handoffReady = decoded.status == mdsMarkerFreeBoundary
  result.decodedLength = uint64(decoded.output.count)
  result.output = decoded.output.storage
  decoded.output.storage = SharedBuffer()
  if decoded.status notin {mdsBoundary, mdsStreamEnd,
                            mdsMarkerFreeBoundary}:
    result.status = jrsRejected

proc processResolution(job: var DecodeJob; arg: WorkerThreadArg): JobResult =
  result = JobResult(ordinal: job.ordinal, generation: job.generation,
                     status: jrsOk, startBit: job.startBit,
                     endBit: job.stopBit)
  if job.markerInput.data.isNil or job.symbolCount < 0 or
     job.symbolCount > job.markerInput.capacity:
    if not job.markerInput.data.isNil: job.markerInput.release()
    if not job.windowInput.data.isNil: job.windowInput.release()
    result.status = jrsError
    result.error.kind = weInvalidJob
    return
  var marked = MarkerBuffer(storage: job.markerInput,
                            count: job.symbolCount,
                            markerCount: job.sourceMarkerCount,
                            maximum: job.markerInput.capacity)
  job.markerInput = SharedBuffer()
  var predecessor: ResolvedWindow
  if not job.windowInput.data.isNil:
    let bytes = cast[ptr UncheckedArray[byte]](job.windowInput.data)
    predecessor = initResolvedWindow(
      bytes.toOpenArray(0, job.windowInput.length - 1))
    job.windowInput.release(boWorker)
  var resolved: SharedBuffer
  let status = resolveMarkers(marked, predecessor, resolved,
                              job.outputTracker)
  marked.release(boWorker)
  if status != mrsOk:
    result.status = jrsError
    result.error.kind = weInternal
    return
  if not resolved.transfer(boCoordinator, boWorker):
    resolved.release()
    result.status = jrsError
    result.error.kind = weInternal
    return
  result.output = resolved
  result.decodedLength = uint64(resolved.length)

proc workerMain(arg: WorkerThreadArg) {.thread.} =
  let active = arg.stats.active.fetchAdd(1, moRelaxed) + 1
  arg.stats.updatePeak(active)
  discard arg.stats.started.fetchAdd(1, moRelaxed)
  defer:
    discard arg.stats.active.fetchSub(1, moRelaxed)

  var inflater: GzInflaterHandle
  var inputPage: SharedBuffer
  var markerWorkspace: MarkerDecoderWorkspace
  if arg.mode == wmMembers:
    inflater = gzInflaterCreate()
    try:
      inputPage = allocSharedBuffer(arg.inputPageSize, owner = boWorker,
                                    tracker = arg.tracker)
    except CatchableError:
      discard
  elif arg.mode == wmMarkers:
    markerWorkspace = newMarkerDecoderWorkspace()
  defer:
    if not inputPage.data.isNil:
      inputPage.release(boWorker)
    if not inflater.isNil:
      gzInflaterDestroy(inflater)

  while not arg.cancellation[].isCancelled():
    var job: DecodeJob
    let takeStatus = arg.jobs[].pop(job, arg.cancellation)
    if takeStatus != qsOk:
      break
    if job.kind == jkShutdown:
      break

    if job.delayMs > 0:
      sleep(job.delayMs)
    var result: JobResult
    if arg.cancellation[].isCancelled():
      result = failedMember(job, weCancelled, job.compressedStart)
    else:
      try:
        if job.kind == jkResolveMarkers:
          result = processResolution(job, arg)
        elif arg.mode == wmMembers and job.kind == jkDecodeBgzfGroup:
          result = processBgzfGroup(job, arg, inflater, inputPage)
        elif arg.mode == wmMembers:
          result = processMember(job, arg, inflater, inputPage)
        elif arg.mode == wmMarkers:
          result = processMarker(job, arg, markerWorkspace)
        else:
          result = processSynthetic(job, arg)
      except GzFastError as error:
        if not job.markerInput.data.isNil: job.markerInput.release()
        if not job.windowInput.data.isNil: job.windowInput.release()
        if not result.output.data.isNil:
          result.output.release()
        result = failedMember(job, weInternal, error.compressedOffset)
      except CatchableError:
        if not job.markerInput.data.isNil: job.markerInput.release()
        if not job.windowInput.data.isNil: job.windowInput.release()
        if not result.output.data.isNil:
          result.output.release()
        result.status = jrsError
        result.error.kind = weAllocation

    if not result.output.data.isNil and
       not result.output.transfer(boWorker, boResultQueue):
      result.output.release()
      result.status = jrsError
      result.error.kind = weInternal

    let publishStatus = arg.results[].push(result, arg.cancellation)
    if publishStatus != qsOk:
      if not result.output.data.isNil:
        result.output.release(boResultQueue)
      break
    # Queue storage now owns the copied POD handle; clear the stale local.
    result = JobResult()
    discard arg.stats.completed.fetchAdd(1, moRelaxed)

proc startWorkerPool*(pool: var WorkerPool; workerCount: int;
                      jobs: var BoundedQueue[DecodeJob];
                      results: var BoundedQueue[JobResult];
                      cancellation: var CancellationToken;
                      tracker: ptr AllocationTracker) =
  if workerCount <= 0:
    raise newException(ValueError, "workerCount must be positive")
  if pool.started:
    raise newException(ValueError, "worker pool already started")
  pool.stats.active.store(0)
  pool.stats.peak.store(0)
  pool.stats.started.store(0)
  pool.stats.completed.store(0)
  pool.threads = newSeq[Thread[WorkerThreadArg]](workerCount)
  pool.started = true
  for i in 0 ..< workerCount:
    createThread(pool.threads[i], workerMain,
      WorkerThreadArg(jobs: addr jobs, results: addr results,
                      cancellation: addr cancellation, tracker: tracker,
                      stats: addr pool.stats, mode: wmSynthetic))

proc startMemberWorkerPool*(pool: var WorkerPool; workerCount: int;
                            jobs: var BoundedQueue[DecodeJob];
                            results: var BoundedQueue[JobResult];
                            cancellation: var CancellationToken;
                            tracker: ptr AllocationTracker;
                            source: ReadAtSource;
                            inputPageSize, maxHeaderSize,
                            maxMemberOutput: int) =
  if workerCount <= 0 or inputPageSize <= 0 or maxHeaderSize <= 0 or
     maxMemberOutput <= 0:
    raise newException(ValueError, "invalid member worker configuration")
  if pool.started:
    raise newException(ValueError, "worker pool already started")
  pool.stats.active.store(0)
  pool.stats.peak.store(0)
  pool.stats.started.store(0)
  pool.stats.completed.store(0)
  pool.threads = newSeq[Thread[WorkerThreadArg]](workerCount)
  pool.started = true
  for i in 0 ..< workerCount:
    createThread(pool.threads[i], workerMain,
      WorkerThreadArg(jobs: addr jobs, results: addr results,
                      cancellation: addr cancellation, tracker: tracker,
                      stats: addr pool.stats, mode: wmMembers,
                      source: source, inputPageSize: inputPageSize,
                      maxHeaderSize: maxHeaderSize,
                      maxMemberOutput: maxMemberOutput))

proc startMarkerWorkerPool*(pool: var WorkerPool; workerCount: int;
                            jobs: var BoundedQueue[DecodeJob];
                            results: var BoundedQueue[JobResult];
                            cancellation: var CancellationToken;
                            tracker: ptr AllocationTracker;
                            source: ReadAtSource;
                            inputPageSize, maximumOutput: int) =
  if workerCount <= 0 or inputPageSize <= 0 or maximumOutput <= 0:
    raise newException(ValueError, "invalid marker worker configuration")
  if pool.started:
    raise newException(ValueError, "worker pool already started")
  pool.stats.active.store(0)
  pool.stats.peak.store(0)
  pool.stats.started.store(0)
  pool.stats.completed.store(0)
  pool.threads = newSeq[Thread[WorkerThreadArg]](workerCount)
  pool.started = true
  for i in 0 ..< workerCount:
    createThread(pool.threads[i], workerMain,
      WorkerThreadArg(jobs: addr jobs, results: addr results,
                      cancellation: addr cancellation, tracker: tracker,
                      stats: addr pool.stats, mode: wmMarkers,
                      source: source, inputPageSize: inputPageSize,
                      maxMemberOutput: maximumOutput))

proc join*(pool: var WorkerPool) =
  if not pool.started or pool.joined:
    return
  for i in 0 ..< pool.threads.len:
    joinThread(pool.threads[i])
  pool.joined = true

proc snapshot*(pool: var WorkerPool): WorkerStatsSnapshot =
  WorkerStatsSnapshot(
    active: pool.stats.active.load(moRelaxed),
    peak: pool.stats.peak.load(moRelaxed),
    started: pool.stats.started.load(moRelaxed),
    completed: pool.stats.completed.load(moRelaxed)
  )

proc workerCount*(pool: WorkerPool): int =
  pool.threads.len

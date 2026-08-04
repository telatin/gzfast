## Lifecycle owner for the Milestone 4 bounded worker runtime.

import ../buffers
import ../config
import ../source
import ./bounded_queue, ./coordinator, ./jobs, ./workers

type
  RuntimeNextStatus* = enum
    rnsOk
    rnsClosed
    rnsCancelled
    rnsCoordinatorError

  SyntheticRuntime* = ref object
    cancellation*: CancellationToken
    jobs*: BoundedQueue[DecodeJob]
    results*: BoundedQueue[JobResult]
    coordinator*: OrderedCoordinator
    tracker*: AllocationTracker
    pool*: WorkerPool
    joined: bool
    deinitialized: bool

  MemberRuntime* = ref object
    sourceOwner*: OwnedReadAtSource
    cancellation*: CancellationToken
    jobs*: BoundedQueue[DecodeJob]
    results*: BoundedQueue[JobResult]
    coordinator*: OrderedCoordinator
    tracker*: AllocationTracker
    pool*: WorkerPool
    joined: bool
    deinitialized: bool

  MarkerRuntime* = ref object
    sourceOwner*: OwnedReadAtSource
    cancellation*: CancellationToken
    jobs*: BoundedQueue[DecodeJob]
    results*: BoundedQueue[JobResult]
    coordinator*: OrderedCoordinator
    tracker*: AllocationTracker
    pool*: WorkerPool
    joined: bool
    deinitialized: bool

proc initSyntheticRuntime*(workerCount, queueCapacity,
                           reorderCapacity: int): SyntheticRuntime =
  result = SyntheticRuntime()
  result.cancellation.initCancellationToken()
  result.tracker.initAllocationTracker()
  result.jobs.initBoundedQueue(queueCapacity)
  result.results.initBoundedQueue(queueCapacity)
  result.coordinator.initOrderedCoordinator(reorderCapacity)
  result.pool.startWorkerPool(workerCount, result.jobs, result.results,
                              result.cancellation, addr result.tracker)

proc submit*(runtime: SyntheticRuntime; job: DecodeJob): QueueStatus =
  runtime.jobs.push(job, addr runtime.cancellation)

proc closeAdmission*(runtime: SyntheticRuntime) =
  runtime.jobs.close()

proc nextOrdered*(runtime: SyntheticRuntime;
                  outResult: var JobResult): RuntimeNextStatus =
  ## Wait until the next ordinal is available, buffering later results.
  while not runtime.coordinator.popReady(outResult):
    var incoming: JobResult
    case runtime.results.pop(incoming, addr runtime.cancellation)
    of qsOk:
      if runtime.coordinator.insert(incoming) != cisAccepted:
        if not incoming.output.data.isNil:
          incoming.output.release(boResultQueue)
        return rnsCoordinatorError
    of qsCancelled:
      return rnsCancelled
    of qsClosed:
      return rnsClosed
    else:
      return rnsCoordinatorError
  rnsOk

proc joinWorkers*(runtime: SyntheticRuntime) =
  ## Close admission first. Results must be consumed concurrently or
  ## beforehand so workers cannot remain blocked on a full result queue.
  runtime.closeAdmission()
  runtime.pool.join()
  runtime.joined = true
  runtime.results.close()

proc drainResultQueue(runtime: SyntheticRuntime) =
  var result: JobResult
  while runtime.results.tryPop(result) == qsOk:
    if not result.output.data.isNil:
      result.output.release(boResultQueue)

proc cancelAndJoin*(runtime: SyntheticRuntime) =
  ## Deterministic shutdown: stop admission, wake every waiter, join,
  ## then release every buffer still owned by queues/coordinator.
  if runtime.isNil or runtime.deinitialized:
    return
  runtime.cancellation.requestCancel()
  runtime.jobs.close()
  runtime.results.close()
  runtime.jobs.wakeAll()
  runtime.results.wakeAll()
  runtime.pool.join()
  runtime.joined = true
  runtime.drainResultQueue()
  runtime.coordinator.drainAndRelease()

proc deinit*(runtime: SyntheticRuntime) =
  if runtime.isNil or runtime.deinitialized:
    return
  if not runtime.joined:
    runtime.cancelAndJoin()
  else:
    runtime.drainResultQueue()
    runtime.coordinator.drainAndRelease()
  runtime.jobs.deinitBoundedQueue()
  runtime.results.deinitBoundedQueue()
  runtime.coordinator.deinitOrderedCoordinator()
  runtime.deinitialized = true

proc allocations*(runtime: SyntheticRuntime): AllocationSnapshot =
  runtime.tracker.snapshot()

proc workerStats*(runtime: SyntheticRuntime): WorkerStatsSnapshot =
  runtime.pool.snapshot()

proc initMemberRuntime*(path: string; config: GzFastConfig;
                        workerCount, queueCapacity,
                        reorderCapacity: int): MemberRuntime =
  let owner = openReadAtSource(path)
  result = MemberRuntime(sourceOwner: owner)
  result.cancellation.initCancellationToken()
  result.tracker.initAllocationTracker()
  result.jobs.initBoundedQueue(queueCapacity)
  result.results.initBoundedQueue(queueCapacity)
  result.coordinator.initOrderedCoordinator(reorderCapacity)
  result.pool.startMemberWorkerPool(workerCount, result.jobs, result.results,
    result.cancellation, addr result.tracker, result.sourceOwner.view,
    config.inputPageSize, config.maxHeaderSize, config.maxSpeculativeOutput)

proc initMemberRuntime*(owner: OwnedReadAtSource; config: GzFastConfig;
                        workerCount, queueCapacity,
                        reorderCapacity: int): MemberRuntime =
  if owner.isNil:
    raise newException(ValueError, "nil member source owner")
  result = MemberRuntime(sourceOwner: owner)
  result.cancellation.initCancellationToken()
  result.tracker.initAllocationTracker()
  result.jobs.initBoundedQueue(queueCapacity)
  result.results.initBoundedQueue(queueCapacity)
  result.coordinator.initOrderedCoordinator(reorderCapacity)
  result.pool.startMemberWorkerPool(workerCount, result.jobs, result.results,
    result.cancellation, addr result.tracker, result.sourceOwner.view,
    config.inputPageSize, config.maxHeaderSize, config.maxSpeculativeOutput)

proc submit*(runtime: MemberRuntime; job: DecodeJob): QueueStatus =
  runtime.jobs.push(job, addr runtime.cancellation)

proc closeAdmission*(runtime: MemberRuntime) =
  runtime.jobs.close()

proc nextOrdered*(runtime: MemberRuntime;
                  outResult: var JobResult): RuntimeNextStatus =
  while not runtime.coordinator.popReady(outResult):
    var incoming: JobResult
    case runtime.results.pop(incoming, addr runtime.cancellation)
    of qsOk:
      if runtime.coordinator.insert(incoming) != cisAccepted:
        if not incoming.output.data.isNil:
          incoming.output.release(boResultQueue)
        return rnsCoordinatorError
    of qsCancelled:
      return rnsCancelled
    of qsClosed:
      return rnsClosed
    else:
      return rnsCoordinatorError
  rnsOk

proc joinWorkers*(runtime: MemberRuntime) =
  runtime.closeAdmission()
  runtime.pool.join()
  runtime.joined = true
  runtime.results.close()

proc drainResultQueue(runtime: MemberRuntime) =
  var result: JobResult
  while runtime.results.tryPop(result) == qsOk:
    if not result.output.data.isNil:
      result.output.release(boResultQueue)

proc cancelAndJoin*(runtime: MemberRuntime) =
  if runtime.isNil or runtime.deinitialized:
    return
  runtime.cancellation.requestCancel()
  runtime.jobs.close()
  runtime.results.close()
  runtime.jobs.wakeAll()
  runtime.results.wakeAll()
  runtime.pool.join()
  runtime.joined = true
  runtime.drainResultQueue()
  runtime.coordinator.drainAndRelease()

proc deinit*(runtime: MemberRuntime) =
  if runtime.isNil or runtime.deinitialized:
    return
  if not runtime.joined:
    runtime.cancelAndJoin()
  else:
    runtime.drainResultQueue()
    runtime.coordinator.drainAndRelease()
  runtime.jobs.deinitBoundedQueue()
  runtime.results.deinitBoundedQueue()
  runtime.coordinator.deinitOrderedCoordinator()
  runtime.sourceOwner.close()
  runtime.deinitialized = true

proc allocations*(runtime: MemberRuntime): AllocationSnapshot =
  runtime.tracker.snapshot()

proc workerStats*(runtime: MemberRuntime): WorkerStatsSnapshot =
  runtime.pool.snapshot()

proc source*(runtime: MemberRuntime): ReadAtSource =
  runtime.sourceOwner.view

proc initMarkerRuntime*(owner: OwnedReadAtSource; config: GzFastConfig;
                        workerCount, queueCapacity,
                        reorderCapacity: int): MarkerRuntime =
  if owner.isNil:
    raise newException(ValueError, "nil marker source owner")
  result = MarkerRuntime(sourceOwner: owner)
  result.cancellation.initCancellationToken()
  result.tracker.initAllocationTracker()
  result.jobs.initBoundedQueue(queueCapacity)
  result.results.initBoundedQueue(queueCapacity)
  result.coordinator.initOrderedCoordinator(reorderCapacity)
  result.pool.startMarkerWorkerPool(workerCount, result.jobs, result.results,
    result.cancellation, addr result.tracker, owner.view,
    config.inputPageSize, config.maxSpeculativeOutput)

proc initMarkerRuntime*(path: string; config: GzFastConfig;
                        workerCount, queueCapacity,
                        reorderCapacity: int): MarkerRuntime =
  let owner = openReadAtSource(path)
  try:
    result = initMarkerRuntime(owner, config, workerCount,
                               queueCapacity, reorderCapacity)
  except CatchableError:
    owner.close()
    raise

proc submit*(runtime: MarkerRuntime; job: DecodeJob): QueueStatus =
  runtime.jobs.push(job, addr runtime.cancellation)

proc closeAdmission*(runtime: MarkerRuntime) = runtime.jobs.close()

proc nextOrdered*(runtime: MarkerRuntime;
                  outResult: var JobResult): RuntimeNextStatus =
  while not runtime.coordinator.popReady(outResult):
    var incoming: JobResult
    case runtime.results.pop(incoming, addr runtime.cancellation)
    of qsOk:
      if runtime.coordinator.insert(incoming) != cisAccepted:
        if not incoming.output.data.isNil:
          incoming.output.release(boResultQueue)
        return rnsCoordinatorError
    of qsCancelled: return rnsCancelled
    of qsClosed: return rnsClosed
    else: return rnsCoordinatorError
  rnsOk

proc drainResultQueue(runtime: MarkerRuntime) =
  var result: JobResult
  while runtime.results.tryPop(result) == qsOk:
    if not result.output.data.isNil:
      result.output.release(boResultQueue)

proc drainMarkerJobs(runtime: MarkerRuntime) =
  var job: DecodeJob
  while runtime.jobs.tryPop(job) == qsOk:
    if not job.markerInput.data.isNil: job.markerInput.release()
    if not job.windowInput.data.isNil: job.windowInput.release()

proc cancelAndJoin*(runtime: MarkerRuntime) =
  if runtime.isNil or runtime.deinitialized: return
  runtime.cancellation.requestCancel()
  runtime.jobs.close(); runtime.results.close()
  runtime.jobs.wakeAll(); runtime.results.wakeAll()
  runtime.pool.join()
  runtime.joined = true
  runtime.drainMarkerJobs()
  runtime.drainResultQueue()
  runtime.coordinator.drainAndRelease()

proc joinWorkers*(runtime: MarkerRuntime) =
  runtime.closeAdmission()
  runtime.pool.join()
  runtime.joined = true
  runtime.results.close()

proc deinit*(runtime: MarkerRuntime) =
  if runtime.isNil or runtime.deinitialized: return
  if not runtime.joined: runtime.cancelAndJoin()
  else:
    runtime.drainResultQueue()
    runtime.coordinator.drainAndRelease()
  runtime.jobs.deinitBoundedQueue()
  runtime.results.deinitBoundedQueue()
  runtime.coordinator.deinitOrderedCoordinator()
  runtime.sourceOwner.close()
  runtime.deinitialized = true

proc allocations*(runtime: MarkerRuntime): AllocationSnapshot =
  runtime.tracker.snapshot()
proc workerStats*(runtime: MarkerRuntime): WorkerStatsSnapshot =
  runtime.pool.snapshot()
proc source*(runtime: MarkerRuntime): ReadAtSource = runtime.sourceOwner.view

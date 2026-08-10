## Milestone 4 worker lifecycle, ordered coordinator and cleanup tests.

import std/[os, unittest]
import gzfast/buffers
import gzfast/config
import gzfast/source
import gzfast/scheduler/[bounded_queue, controller, coordinator, jobs]

proc checkPayload(result: JobResult; expected: byte) =
  check result.output.owner == boCoordinator
  check result.output.length == int(result.decodedLength)
  let bytes = cast[ptr UncheckedArray[byte]](result.output.data)
  for i in 0 ..< result.output.length:
    check bytes[i] == expected

proc releaseResult(result: var JobResult) =
  if not result.output.data.isNil:
    result.output.release(boCoordinator)

suite "ordered coordinator":
  test "out-of-order results become ready in ordinal order":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var coordinator: OrderedCoordinator
    coordinator.initOrderedCoordinator(4)
    defer: coordinator.deinitOrderedCoordinator()

    var later = JobResult(ordinal: 1, status: jrsOk,
      output: allocSharedBuffer(2, owner = boResultQueue,
                                tracker = addr tracker))
    later.output.setLength(2)
    var first = JobResult(ordinal: 0, status: jrsOk,
      output: allocSharedBuffer(1, owner = boResultQueue,
                                tracker = addr tracker))
    first.output.setLength(1)
    check coordinator.insert(later) == cisAccepted
    var ready: JobResult
    check not coordinator.popReady(ready)
    check coordinator.insert(first) == cisAccepted
    check coordinator.popReady(ready)
    check ready.ordinal == 0
    ready.releaseResult()
    check coordinator.popReady(ready)
    check ready.ordinal == 1
    ready.releaseResult()
    check coordinator.len == 0
    check tracker.snapshot().currentBytes == 0

  test "duplicate, stale and out-of-window ordinals are rejected":
    var coordinator: OrderedCoordinator
    coordinator.initOrderedCoordinator(2, firstOrdinal = 5)
    defer: coordinator.deinitOrderedCoordinator()
    var accepted = JobResult(ordinal: 6)
    check coordinator.insert(accepted) == cisAccepted
    var duplicate = JobResult(ordinal: 6)
    check coordinator.insert(duplicate) == cisDuplicate
    var stale = JobResult(ordinal: 4)
    check coordinator.insert(stale) == cisStale
    var distant = JobResult(ordinal: 7)
    check coordinator.insert(distant) == cisOutOfWindow

suite "worker runtime":
  test "synthetic jobs complete out of order but emit in order":
    let runtime = initSyntheticRuntime(workerCount = 4, queueCapacity = 8,
                                       reorderCapacity = 8)
    defer: runtime.deinit()
    for ordinal in 0'u64 ..< 8'u64:
      let delay = int(7 - ordinal) * 3
      check runtime.submit(DecodeJob(
        ordinal: ordinal,
        kind: jkDecodeBoundary,
        compressedStart: ordinal * 100,
        compressedEnd: ordinal * 100 + 99,
        generation: 1,
        outputLength: int(ordinal) + 3,
        payloadByte: byte(ordinal + 40),
        delayMs: delay
      )) == qsOk
    runtime.closeAdmission()

    for expected in 0'u64 ..< 8'u64:
      var result: JobResult
      check runtime.nextOrdered(result) == rnsOk
      check result.ordinal == expected
      check result.generation == 1
      check result.status == jrsOk
      result.checkPayload(byte(expected + 40))
      result.releaseResult()
    runtime.joinWorkers()
    let stats = runtime.workerStats()
    check stats.started == 4
    check stats.completed == 8
    check stats.peak >= 2
    check runtime.allocations().currentBytes == 0

  test "worker failures are plain ordered records":
    let runtime = initSyntheticRuntime(2, 4, 4)
    defer: runtime.deinit()
    check runtime.submit(DecodeJob(ordinal: 0,
      kind: jkResolveMarkers, outputLength: 10, delayMs: 20)) == qsOk
    check runtime.submit(DecodeJob(ordinal: 1,
      kind: jkDecodeBoundary, outputLength: 2, payloadByte: 7)) == qsOk
    runtime.closeAdmission()
    var first, second: JobResult
    check runtime.nextOrdered(first) == rnsOk
    check first.status == jrsError
    check first.error.kind == weInvalidJob
    check first.output.data.isNil
    check runtime.nextOrdered(second) == rnsOk
    check second.status == jrsOk
    second.releaseResult()
    runtime.joinWorkers()
    check runtime.allocations().liveBuffers == 0

  test "cancellation drains full queues and worker-owned buffers":
    let runtime = initSyntheticRuntime(4, 2, 4)
    for ordinal in 0'u64 ..< 6'u64:
      check runtime.submit(DecodeJob(
        ordinal: ordinal, kind: jkDecodeBoundary,
        outputLength: 64 * 1024, payloadByte: byte(ordinal),
        delayMs: 2)) == qsOk
    sleep(30) # let the result queue fill and block publishers
    runtime.cancelAndJoin()
    check runtime.workerStats().active == 0
    let allocations = runtime.allocations()
    check allocations.currentBytes == 0
    check allocations.liveBuffers == 0
    check allocations.peakBytes > 0
    check allocations.peakBytes <= int64(6 * 64 * 1024)
    runtime.deinit()

  test "immediate cancellation joins every worker":
    let runtime = initSyntheticRuntime(8, 2, 2)
    runtime.cancelAndJoin()
    check runtime.workerStats().active == 0
    check runtime.allocations().currentBytes == 0
    runtime.deinit()

  test "repeated worker start and shutdown":
    for round in 0 ..< 20:
      let runtime = initSyntheticRuntime(2, 2, 2)
      if (round and 1) == 0:
        check runtime.submit(DecodeJob(ordinal: 0,
          kind: jkDecodeBoundary, outputLength: 32,
          payloadByte: byte(round))) == qsOk
      runtime.cancelAndJoin()
      check runtime.workerStats().active == 0
      check runtime.allocations().currentBytes == 0
      runtime.deinit()

  test "multiple runtime instances have independent state":
    let left = initSyntheticRuntime(2, 4, 4)
    let right = initSyntheticRuntime(3, 4, 4)
    defer:
      left.deinit()
      right.deinit()
    for ordinal in 0'u64 ..< 4'u64:
      check left.submit(DecodeJob(ordinal: ordinal,
        kind: jkDecodeBoundary, outputLength: 5,
        payloadByte: 11)) == qsOk
      check right.submit(DecodeJob(ordinal: ordinal,
        kind: jkDecodeBoundary, outputLength: 7,
        payloadByte: 22)) == qsOk
    left.closeAdmission()
    right.closeAdmission()
    for ordinal in 0'u64 ..< 4'u64:
      var a, b: JobResult
      check left.nextOrdered(a) == rnsOk
      check right.nextOrdered(b) == rnsOk
      check a.ordinal == ordinal
      check b.ordinal == ordinal
      a.checkPayload(11)
      b.checkPayload(22)
      a.releaseResult()
      b.releaseResult()
    left.joinWorkers()
    right.joinWorkers()
    check left.allocations().currentBytes == 0
    check right.allocations().currentBytes == 0

  test "cancellation releases popped resolution job inputs":
    # A resolution job popped just before cancellation carries owned
    # markerInput/windowInput buffers; the queue drain never sees them.
    let owner = openMemoryReadAtSource(newSeq[byte](64))
    let runtime = initMarkerRuntime(owner, defaultGzFastConfig(),
                                    workerCount = 1, queueCapacity = 4,
                                    reorderCapacity = 4)
    var markerInput = allocSharedBuffer(4, elementWidth = 2,
      owner = boWorker, tracker = addr runtime.tracker)
    let symbols = cast[ptr UncheckedArray[uint16]](markerInput.data)
    for i in 0 ..< 4:
      symbols[i] = uint16(ord('a') + i)
    markerInput.setLength(4)
    check runtime.submit(DecodeJob(ordinal: 0, kind: jkResolveMarkers,
      markerInput: markerInput, symbolCount: 4, delayMs: 300)) == qsOk
    sleep(50) # the worker pops the job and sleeps through the delay
    runtime.cancelAndJoin()
    let allocations = runtime.allocations()
    check allocations.currentBytes == 0
    check allocations.liveBuffers == 0
    runtime.deinit()

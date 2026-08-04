## Milestone 4 shared-buffer ownership and accounting tests.

import std/unittest
import gzfast/buffers
import gzfast/errors

suite "shared buffers":
  test "allocation, length and release are tracked":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var buffer = allocSharedBuffer(4096, tracker = addr tracker)
    buffer.setLength(1234)
    check buffer.length == 1234
    check buffer.capacity == 4096
    check buffer.byteCapacity == 4096
    let live = tracker.snapshot()
    check live.currentBytes == 4096
    check live.peakBytes == 4096
    check live.liveBuffers == 1
    check live.totalAllocations == 1
    buffer.release(boWorker)
    let done = tracker.snapshot()
    check done.currentBytes == 0
    check done.liveBuffers == 0

  test "uint16 buffers account element width":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var buffer = allocSharedBuffer(32768, elementWidth = 2,
                                   tracker = addr tracker, zeroed = true)
    check buffer.byteCapacity == 65536
    check buffer.byteAt(17)[] == 0
    buffer.release(boWorker)
    check tracker.snapshot().currentBytes == 0

  test "ownership transfer and move are explicit":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var workerBuffer = allocSharedBuffer(64, tracker = addr tracker)
    check workerBuffer.transfer(boWorker, boResultQueue)
    check not workerBuffer.transfer(boWorker, boCoordinator)
    var coordinatorBuffer = workerBuffer.take(boResultQueue, boCoordinator)
    check workerBuffer.data.isNil
    check coordinatorBuffer.owner == boCoordinator
    coordinatorBuffer.release(boCoordinator)
    check tracker.snapshot().liveBuffers == 0

  test "geometric growth preserves data and accounting":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var buffer = allocSharedBuffer(8, tracker = addr tracker)
    for i in 0 ..< 8:
      buffer.byteAt(i)[] = byte(i + 1)
    buffer.setLength(8)
    buffer.reserve(5000, maximumCapacity = 8192)
    check buffer.capacity == 8192
    check buffer.length == 8
    for i in 0 ..< 8:
      check buffer.byteAt(i)[] == byte(i + 1)
    check tracker.snapshot().currentBytes == 8192
    check tracker.snapshot().liveBuffers == 1
    buffer.release(boWorker)
    check tracker.snapshot().currentBytes == 0

  test "wrong-owner release is rejected without leaking":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var buffer = allocSharedBuffer(64, tracker = addr tracker)
    expect GzFastError:
      buffer.release(boCoordinator)
    check tracker.snapshot().liveBuffers == 1
    buffer.release(boWorker)
    check tracker.snapshot().liveBuffers == 0

  test "zero capacity needs no shared allocation":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    var buffer = allocSharedBuffer(0, tracker = addr tracker)
    check buffer.data.isNil
    check buffer.byteCapacity == 0
    buffer.release()
    check tracker.snapshot().totalAllocations == 0

  test "invalid dimensions and bounds are rejected":
    expect GzFastError:
      discard allocSharedBuffer(-1)
    expect GzFastError:
      discard allocSharedBuffer(high(int), elementWidth = 2)
    var buffer = allocSharedBuffer(8)
    defer: buffer.release(boWorker)
    expect GzFastError:
      buffer.setLength(9)
    expect GzFastError:
      discard buffer.byteAt(8)

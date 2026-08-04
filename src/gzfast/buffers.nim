## Explicitly owned buffers allocated from Nim's shared heap.
##
## SharedBuffer is a POD handle: it has no destructor and must be moved
## with `take` and released explicitly. This makes every worker/queue/
## coordinator ownership transition visible and cancellation-drainable.

import std/atomics
import ./errors

type
  BufferOwner* = enum
    boNone
    boWorker
    boResultQueue
    boCoordinator
    boOutputQueue
    boReader

  AllocationTracker* = object
    currentBytes: Atomic[int64]
    peakBytes: Atomic[int64]
    liveBuffers: Atomic[int]
    totalAllocations: Atomic[uint64]

  AllocationSnapshot* = object
    currentBytes*: int64
    peakBytes*: int64
    liveBuffers*: int
    totalAllocations*: uint64

  SharedBuffer* = object
    data*: pointer
    length*: int
    capacity*: int
    elementWidth*: int
    owner*: BufferOwner
    tracker: ptr AllocationTracker

proc initAllocationTracker*(tracker: var AllocationTracker) =
  tracker.currentBytes.store(0)
  tracker.peakBytes.store(0)
  tracker.liveBuffers.store(0)
  tracker.totalAllocations.store(0)

proc updatePeak(tracker: ptr AllocationTracker; live: int64) =
  if tracker.isNil:
    return
  while true:
    let oldPeak = tracker.peakBytes.load(moRelaxed)
    if live <= oldPeak:
      return
    var expected = oldPeak
    if tracker.peakBytes.compareExchange(expected, live,
        moRelaxed, moRelaxed):
      return

proc recordAllocation(tracker: ptr AllocationTracker; bytes: int64) =
  if tracker.isNil:
    return
  let live = tracker.currentBytes.fetchAdd(bytes, moRelaxed) + bytes
  discard tracker.liveBuffers.fetchAdd(1, moRelaxed)
  discard tracker.totalAllocations.fetchAdd(1, moRelaxed)
  tracker.updatePeak(live)

proc recordRelease(tracker: ptr AllocationTracker; bytes: int64) =
  if tracker.isNil:
    return
  let previous = tracker.currentBytes.fetchSub(bytes, moRelaxed)
  if previous < bytes:
    # Restore the counter before surfacing the internal invariant.
    discard tracker.currentBytes.fetchAdd(bytes, moRelaxed)
    raise newGzFastError(geInternal, "shared allocation counter underflow")
  let previousBuffers = tracker.liveBuffers.fetchSub(1, moRelaxed)
  if previousBuffers <= 0:
    discard tracker.liveBuffers.fetchAdd(1, moRelaxed)
    raise newGzFastError(geInternal, "shared buffer counter underflow")

proc recordResize(tracker: ptr AllocationTracker; oldBytes, newBytes: int64) =
  if tracker.isNil or oldBytes == newBytes:
    return
  if newBytes > oldBytes:
    let delta = newBytes - oldBytes
    let live = tracker.currentBytes.fetchAdd(delta, moRelaxed) + delta
    tracker.updatePeak(live)
  else:
    let delta = oldBytes - newBytes
    let previous = tracker.currentBytes.fetchSub(delta, moRelaxed)
    if previous < delta:
      discard tracker.currentBytes.fetchAdd(delta, moRelaxed)
      raise newGzFastError(geInternal, "shared resize counter underflow")

proc snapshot*(tracker: var AllocationTracker): AllocationSnapshot =
  AllocationSnapshot(
    currentBytes: tracker.currentBytes.load(moRelaxed),
    peakBytes: tracker.peakBytes.load(moRelaxed),
    liveBuffers: tracker.liveBuffers.load(moRelaxed),
    totalAllocations: tracker.totalAllocations.load(moRelaxed)
  )

proc byteCapacity*(buffer: SharedBuffer): int =
  if buffer.capacity == 0 or buffer.elementWidth == 0:
    0
  else:
    buffer.capacity * buffer.elementWidth

proc allocSharedBuffer*(capacity: int; elementWidth = 1;
                        owner = boWorker;
                        tracker: ptr AllocationTracker = nil;
                        zeroed = false): SharedBuffer =
  if capacity < 0 or elementWidth <= 0 or
     (capacity > 0 and capacity > high(int) div elementWidth):
    raise newGzFastError(geInternal, "invalid shared buffer dimensions")
  let bytes = capacity * elementWidth
  if bytes == 0:
    return SharedBuffer(elementWidth: elementWidth, owner: owner,
                        tracker: tracker)
  let data = if zeroed: allocShared0(bytes) else: allocShared(bytes)
  if data.isNil:
    raise newGzFastError(geInternal, "failed to allocate shared buffer")
  result = SharedBuffer(data: data, capacity: capacity,
                        elementWidth: elementWidth, owner: owner,
                        tracker: tracker)
  tracker.recordAllocation(int64(bytes))

proc setLength*(buffer: var SharedBuffer; length: int) =
  if length < 0 or length > buffer.capacity:
    raise newGzFastError(geInternal, "shared buffer length exceeds capacity")
  buffer.length = length

proc reserve*(buffer: var SharedBuffer; minimumCapacity: int;
              maximumCapacity = high(int)) =
  ## Grow geometrically while preserving contents and ownership.
  if minimumCapacity <= buffer.capacity:
    return
  if minimumCapacity < 0 or maximumCapacity < minimumCapacity or
     buffer.elementWidth <= 0:
    raise newGzFastError(geInternal, "invalid shared buffer reserve")
  var next = min(max(buffer.capacity, 4096), maximumCapacity)
  while next < minimumCapacity:
    if next > maximumCapacity div 2:
      next = maximumCapacity
    else:
      next *= 2
    if next < minimumCapacity and next == maximumCapacity:
      raise newGzFastError(geInternal, "shared buffer maximum exceeded")
  if next > high(int) div buffer.elementWidth:
    raise newGzFastError(geInternal, "shared buffer size overflow")
  let oldBytes = buffer.byteCapacity
  let newBytes = next * buffer.elementWidth
  let wasEmpty = buffer.data.isNil
  let resized = reallocShared(buffer.data, newBytes)
  if resized.isNil:
    raise newGzFastError(geInternal, "failed to grow shared buffer")
  buffer.data = resized
  buffer.capacity = next
  if wasEmpty:
    buffer.tracker.recordAllocation(int64(newBytes))
  else:
    buffer.tracker.recordResize(int64(oldBytes), int64(newBytes))

proc transfer*(buffer: var SharedBuffer; expected, next: BufferOwner): bool =
  ## Change ownership only when the caller holds the expected state.
  if buffer.data.isNil or buffer.owner != expected:
    return false
  buffer.owner = next
  true

proc take*(source: var SharedBuffer; expected: BufferOwner;
           next: BufferOwner): SharedBuffer =
  ## Move the handle out of `source`; source becomes empty.
  if source.data.isNil or source.owner != expected:
    raise newGzFastError(geInternal, "invalid shared buffer ownership move")
  result = source
  result.owner = next
  source = SharedBuffer()

proc release*(buffer: var SharedBuffer; expected = boNone) =
  ## Free an owned buffer. When expected != boNone, enforce ownership.
  if buffer.data.isNil:
    buffer = SharedBuffer()
    return
  if expected != boNone and buffer.owner != expected:
    raise newGzFastError(geInternal, "invalid shared buffer release owner")
  let bytes = int64(buffer.byteCapacity)
  let tracker = buffer.tracker
  deallocShared(buffer.data)
  buffer = SharedBuffer()
  tracker.recordRelease(bytes)

proc byteAt*(buffer: SharedBuffer; index: int): ptr byte =
  ## Address one byte in the allocated region (not logical elements).
  if index < 0 or index >= buffer.byteCapacity:
    raise newGzFastError(geInternal, "shared buffer byte index out of bounds")
  cast[ptr byte](cast[uint](buffer.data) + uint(index))

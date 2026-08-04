## Bounded ordinal-ring coordinator for out-of-order worker results.

import ./jobs
import ../buffers

type
  CoordinatorInsertStatus* = enum
    cisAccepted
    cisStale
    cisOutOfWindow
    cisDuplicate

  OrderedCoordinator* = object
    slots: ptr UncheckedArray[JobResult]
    present: ptr UncheckedArray[bool]
    capacityValue: int
    nextOrdinalValue: uint64
    bufferedCount: int
    initialized: bool

proc initOrderedCoordinator*(coordinator: var OrderedCoordinator;
                             capacity: int; firstOrdinal = 0'u64) =
  if capacity <= 0 or capacity > high(int) div sizeof(JobResult):
    raise newException(ValueError, "coordinator capacity must be positive")
  coordinator.slots = cast[ptr UncheckedArray[JobResult]](
    allocShared0(capacity * sizeof(JobResult)))
  coordinator.present = cast[ptr UncheckedArray[bool]](
    allocShared0(capacity * sizeof(bool)))
  if coordinator.slots.isNil or coordinator.present.isNil:
    if not coordinator.slots.isNil:
      deallocShared(cast[pointer](coordinator.slots))
    if not coordinator.present.isNil:
      deallocShared(cast[pointer](coordinator.present))
    raise newException(OutOfMemDefect, "failed to allocate coordinator")
  coordinator.capacityValue = capacity
  coordinator.nextOrdinalValue = firstOrdinal
  coordinator.initialized = true

proc insert*(coordinator: var OrderedCoordinator;
             incoming: var JobResult): CoordinatorInsertStatus =
  if incoming.ordinal < coordinator.nextOrdinalValue:
    return cisStale
  let distance = incoming.ordinal - coordinator.nextOrdinalValue
  if distance >= uint64(coordinator.capacityValue):
    return cisOutOfWindow
  let index = int(incoming.ordinal mod uint64(coordinator.capacityValue))
  if coordinator.present[index]:
    return cisDuplicate
  if not incoming.output.data.isNil:
    if not incoming.output.transfer(boResultQueue, boCoordinator):
      return cisDuplicate
  coordinator.slots[index] = incoming
  incoming = JobResult()
  coordinator.present[index] = true
  inc coordinator.bufferedCount
  cisAccepted

proc popReady*(coordinator: var OrderedCoordinator;
               outResult: var JobResult): bool =
  let index = int(coordinator.nextOrdinalValue mod
                  uint64(coordinator.capacityValue))
  if not coordinator.present[index]:
    return false
  outResult = coordinator.slots[index]
  coordinator.slots[index] = JobResult()
  coordinator.present[index] = false
  inc coordinator.nextOrdinalValue
  dec coordinator.bufferedCount
  true

proc drainAndRelease*(coordinator: var OrderedCoordinator) =
  if not coordinator.initialized:
    return
  for i in 0 ..< coordinator.capacityValue:
    if coordinator.present[i]:
      if not coordinator.slots[i].output.data.isNil:
        coordinator.slots[i].output.release(boCoordinator)
      coordinator.slots[i] = JobResult()
      coordinator.present[i] = false
  coordinator.bufferedCount = 0

proc deinitOrderedCoordinator*(coordinator: var OrderedCoordinator) =
  if not coordinator.initialized:
    return
  coordinator.drainAndRelease()
  deallocShared(cast[pointer](coordinator.slots))
  deallocShared(cast[pointer](coordinator.present))
  coordinator = OrderedCoordinator()

proc len*(coordinator: OrderedCoordinator): int =
  coordinator.bufferedCount

proc capacity*(coordinator: OrderedCoordinator): int =
  coordinator.capacityValue

proc nextOrdinal*(coordinator: OrderedCoordinator): uint64 =
  coordinator.nextOrdinalValue

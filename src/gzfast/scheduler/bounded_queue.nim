## Fixed-capacity blocking queue for POD worker messages.
##
## The ring storage is allocated from the shared heap. Closing stops
## admission and wakes every waiter; consumers may drain items already
## present before receiving qsClosed.

import std/[atomics, locks, typetraits]

type
  QueueStatus* = enum
    qsOk
    qsClosed
    qsCancelled
    qsEmpty
    qsFull

  CancellationToken* = object
    requested: Atomic[bool]

  BoundedQueue*[T] = object
    slots: ptr UncheckedArray[T]
    capacityValue: int
    head, tail, itemCount: int
    lock: Lock
    notEmpty, notFull: Cond
    closed: bool
    initialized: bool

proc initCancellationToken*(token: var CancellationToken) =
  token.requested.store(false)

proc requestCancel*(token: var CancellationToken) =
  token.requested.store(true, moRelease)

proc isCancelled*(token: var CancellationToken): bool =
  token.requested.load(moAcquire)

proc cancellationRequested(token: ptr CancellationToken): bool =
  not token.isNil and token[].isCancelled()

proc initBoundedQueue*[T](queue: var BoundedQueue[T]; capacity: int) =
  when not supportsCopyMem(T):
    {.error: "BoundedQueue messages must be POD/copyMem-safe".}
  if capacity <= 0 or capacity > high(int) div sizeof(T):
    raise newException(ValueError, "queue capacity must be positive")
  if queue.initialized:
    raise newException(ValueError, "queue is already initialized")
  queue.slots = cast[ptr UncheckedArray[T]](
    allocShared0(capacity * sizeof(T)))
  if queue.slots.isNil:
    raise newException(OutOfMemDefect, "failed to allocate bounded queue")
  queue.capacityValue = capacity
  queue.lock.initLock()
  queue.notEmpty.initCond()
  queue.notFull.initCond()
  queue.initialized = true

proc wakeAll*[T](queue: var BoundedQueue[T]) =
  ## Wake waiters after an external cancellation flag changes.
  if not queue.initialized:
    return
  queue.lock.acquire()
  try:
    queue.notEmpty.broadcast()
    queue.notFull.broadcast()
  finally:
    queue.lock.release()

proc close*[T](queue: var BoundedQueue[T]) =
  ## Stop admission and wake blocked producers/consumers. Idempotent.
  if not queue.initialized:
    return
  queue.lock.acquire()
  try:
    queue.closed = true
    queue.notEmpty.broadcast()
    queue.notFull.broadcast()
  finally:
    queue.lock.release()

proc push*[T](queue: var BoundedQueue[T]; item: T;
              cancellation: ptr CancellationToken = nil): QueueStatus =
  queue.lock.acquire()
  try:
    while queue.itemCount == queue.capacityValue and not queue.closed and
          not cancellation.cancellationRequested():
      queue.notFull.wait(queue.lock)
    if cancellation.cancellationRequested():
      return qsCancelled
    if queue.closed:
      return qsClosed
    queue.slots[queue.tail] = item
    queue.tail = (queue.tail + 1) mod queue.capacityValue
    inc queue.itemCount
    queue.notEmpty.signal()
    qsOk
  finally:
    queue.lock.release()

proc pop*[T](queue: var BoundedQueue[T]; item: var T;
             cancellation: ptr CancellationToken = nil): QueueStatus =
  queue.lock.acquire()
  try:
    while queue.itemCount == 0 and not queue.closed and
          not cancellation.cancellationRequested():
      queue.notEmpty.wait(queue.lock)
    if cancellation.cancellationRequested():
      return qsCancelled
    if queue.itemCount == 0 and queue.closed:
      return qsClosed
    item = queue.slots[queue.head]
    queue.slots[queue.head] = default(T)
    queue.head = (queue.head + 1) mod queue.capacityValue
    dec queue.itemCount
    queue.notFull.signal()
    qsOk
  finally:
    queue.lock.release()

proc tryPush*[T](queue: var BoundedQueue[T]; item: T): QueueStatus =
  queue.lock.acquire()
  try:
    if queue.closed:
      return qsClosed
    if queue.itemCount == queue.capacityValue:
      return qsFull
    queue.slots[queue.tail] = item
    queue.tail = (queue.tail + 1) mod queue.capacityValue
    inc queue.itemCount
    queue.notEmpty.signal()
    qsOk
  finally:
    queue.lock.release()

proc tryPop*[T](queue: var BoundedQueue[T]; item: var T): QueueStatus =
  queue.lock.acquire()
  try:
    if queue.itemCount == 0:
      return (if queue.closed: qsClosed else: qsEmpty)
    item = queue.slots[queue.head]
    queue.slots[queue.head] = default(T)
    queue.head = (queue.head + 1) mod queue.capacityValue
    dec queue.itemCount
    queue.notFull.signal()
    qsOk
  finally:
    queue.lock.release()

proc len*[T](queue: var BoundedQueue[T]): int =
  queue.lock.acquire()
  try:
    queue.itemCount
  finally:
    queue.lock.release()

proc capacity*[T](queue: BoundedQueue[T]): int =
  queue.capacityValue

proc isClosed*[T](queue: var BoundedQueue[T]): bool =
  queue.lock.acquire()
  try:
    queue.closed
  finally:
    queue.lock.release()

proc deinitBoundedQueue*[T](queue: var BoundedQueue[T]) =
  ## Caller must stop all users and drain owned payloads first.
  if not queue.initialized:
    return
  queue.close()
  deallocShared(cast[pointer](queue.slots))
  queue.notEmpty.deinitCond()
  queue.notFull.deinitCond()
  queue.lock.deinitLock()
  queue = BoundedQueue[T]()

## Milestone 4 bounded queue, close and cancellation tests.

import std/[atomics, os, typedthreads, unittest]
import gzfast/scheduler/bounded_queue

type
  QueueThreadArg = object
    queue: ptr BoundedQueue[int]
    token: ptr CancellationToken
    result: ptr Atomic[int]
    value: int

proc blockedProducer(arg: QueueThreadArg) {.thread.} =
  let status = arg.queue[].push(arg.value, arg.token)
  arg.result[].store(ord(status))

proc blockedConsumer(arg: QueueThreadArg) {.thread.} =
  var value: int
  let status = arg.queue[].pop(value, arg.token)
  arg.result[].store(ord(status))

suite "bounded queue":
  test "FIFO and wraparound":
    var queue: BoundedQueue[int]
    queue.initBoundedQueue(3)
    defer: queue.deinitBoundedQueue()
    check queue.push(1) == qsOk
    check queue.push(2) == qsOk
    check queue.push(3) == qsOk
    check queue.tryPush(4) == qsFull
    var value: int
    check queue.pop(value) == qsOk
    check value == 1
    check queue.push(4) == qsOk
    for expected in [2, 3, 4]:
      check queue.pop(value) == qsOk
      check value == expected
    check queue.tryPop(value) == qsEmpty

  test "close while empty wakes blocked consumer":
    var queue: BoundedQueue[int]
    queue.initBoundedQueue(1)
    var token: CancellationToken
    token.initCancellationToken()
    var result: Atomic[int]
    result.store(-1)
    var thread: Thread[QueueThreadArg]
    createThread(thread, blockedConsumer,
      QueueThreadArg(queue: addr queue, token: addr token,
                     result: addr result))
    sleep(20)
    queue.close()
    joinThread(thread)
    check QueueStatus(result.load()) == qsClosed
    queue.deinitBoundedQueue()

  test "close while full wakes blocked producer":
    var queue: BoundedQueue[int]
    queue.initBoundedQueue(1)
    check queue.push(1) == qsOk
    var token: CancellationToken
    token.initCancellationToken()
    var result: Atomic[int]
    result.store(-1)
    var thread: Thread[QueueThreadArg]
    createThread(thread, blockedProducer,
      QueueThreadArg(queue: addr queue, token: addr token,
                     result: addr result, value: 2))
    sleep(20)
    queue.close()
    joinThread(thread)
    check QueueStatus(result.load()) == qsClosed
    var value: int
    check queue.pop(value) == qsOk # queued item remains drainable
    check value == 1
    check queue.pop(value) == qsClosed
    queue.deinitBoundedQueue()

  test "blocked producer observes cancellation":
    var queue: BoundedQueue[int]
    queue.initBoundedQueue(1)
    check queue.push(1) == qsOk
    var token: CancellationToken
    token.initCancellationToken()
    var result: Atomic[int]
    result.store(-1)
    var thread: Thread[QueueThreadArg]
    createThread(thread, blockedProducer,
      QueueThreadArg(queue: addr queue, token: addr token,
                     result: addr result, value: 2))
    sleep(20)
    token.requestCancel()
    queue.wakeAll()
    joinThread(thread)
    check QueueStatus(result.load()) == qsCancelled
    queue.close()
    var value: int
    discard queue.tryPop(value)
    queue.deinitBoundedQueue()

  test "blocked consumer observes cancellation":
    var queue: BoundedQueue[int]
    queue.initBoundedQueue(1)
    var token: CancellationToken
    token.initCancellationToken()
    var result: Atomic[int]
    result.store(-1)
    var thread: Thread[QueueThreadArg]
    createThread(thread, blockedConsumer,
      QueueThreadArg(queue: addr queue, token: addr token,
                     result: addr result))
    sleep(20)
    token.requestCancel()
    queue.wakeAll()
    joinThread(thread)
    check QueueStatus(result.load()) == qsCancelled
    queue.close()
    queue.deinitBoundedQueue()

  test "repeated initialize and shutdown":
    for round in 0 ..< 50:
      var queue: BoundedQueue[int]
      queue.initBoundedQueue(2)
      check queue.capacity == 2
      check queue.push(round) == qsOk
      queue.close()
      var value: int
      check queue.pop(value) == qsOk
      check value == round
      check queue.pop(value) == qsClosed
      queue.deinitBoundedQueue()

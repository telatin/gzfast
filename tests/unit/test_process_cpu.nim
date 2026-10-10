## Process accounting must include worker CPU after the worker has exited.

import std/unittest
import gzfast/private/process_cpu

when defined(posix):
  import std/[times, typedthreads]

  type WorkerMeasurement = object
    seconds: float
    checksum: uint64

  proc burnCpu(measurement: ptr WorkerMeasurement) {.thread.} =
    # On Linux cpuTime() measures this worker, independently of the process
    # clock under test. CPU-based termination avoids wall-time/load flakiness.
    let start = cpuTime()
    var checksum = 1'u64
    while cpuTime() - start < 0.12:
      for _ in 0 ..< 4096:
        checksum = (checksum xor (checksum shr 7)) * 1664525'u64 + 1013904223'u64
    measurement.seconds = cpuTime() - start
    measurement.checksum = checksum

suite "process CPU accounting":
  test "samples are nonnegative and monotonic":
    let start = processCpuTime()
    check start >= 0
    check processCpuTime() >= start

  when defined(posix):
    test "joined workers contribute to process CPU time":
      var measurement: WorkerMeasurement
      var worker: Thread[ptr WorkerMeasurement]
      let start = processCpuTime()
      createThread(worker, burnCpu, addr measurement)
      joinThread(worker)
      let elapsed = processCpuTime() - start
      check measurement.seconds >= 0.12
      check measurement.checksum != 0
      check elapsed >= measurement.seconds - 0.02

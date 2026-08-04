import std/unittest
import gzfast/scheduler/adaptive

suite "adaptive worker bootstrap":
  test "small budgets use full allowance":
    for maximum in 1 .. 4:
      check initialWorkerTarget(maximum) == maximum

  test "larger budgets use square-root bootstrap":
    check initialWorkerTarget(16) == 8
    check initialWorkerTarget(44) == 14
    check initialWorkerTarget(64) == 16

  test "visible work and invalid inputs cap creation":
    check initialWorkerTarget(64, availableWork = 3) == 3
    check initialWorkerTarget(0) == 0
    check initialWorkerTarget(8, availableWork = 0) == 0

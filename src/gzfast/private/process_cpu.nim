## CPU accounting for CLI statistics, including completed worker threads.

when defined(posix):
  import std/[os, posix]
else:
  import std/times

proc processCpuTime*(): float =
  ## POSIX: cumulative process user + system CPU seconds, not thread time.
  ## Other platforms retain the CLI's existing platform clock behavior.
  when defined(posix):
    var usage: Rusage
    if getrusage(RUSAGE_SELF, addr usage) != 0:
      raiseOSError(osLastError())
    result = usage.ru_utime.tv_sec.float + usage.ru_stime.tv_sec.float +
      (usage.ru_utime.tv_usec.float + usage.ru_stime.tv_usec.float) / 1e6
  else:
    result = cpuTime()

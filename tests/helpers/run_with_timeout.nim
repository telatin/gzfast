## Cross-platform child-process timeout used by concurrency stress tasks.

import std/[os, osproc, strutils]

when isMainModule:
  if paramCount() < 2:
    quit("usage: run_with_timeout MILLISECONDS EXECUTABLE [ARGS...]", 2)
  let timeoutMs = parseInt(paramStr(1))
  var executable = paramStr(2)
  when defined(windows):
    if not fileExists(executable) and fileExists(executable & ".exe"):
      executable.add(".exe")
  var arguments: seq[string]
  for index in 3 .. paramCount(): arguments.add(paramStr(index))
  let child = startProcess(executable, workingDir = getCurrentDir(),
                           args = arguments,
                           options = {poParentStreams, poUsePath})
  var elapsed = 0
  while child.running and elapsed < timeoutMs:
    sleep(10)
    elapsed += 10
  if child.running:
    child.terminate()
    discard child.waitForExit()
    child.close()
    quit("test timed out after " & $timeoutMs & " ms: " & executable, 124)
  let code = child.waitForExit()
  child.close()
  quit(code)

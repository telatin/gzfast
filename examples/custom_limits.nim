## Decode with custom resource limits (decompression-bomb guard).
##
## Compile from the checkout:
## nim c -d:release --threads:on -p:src examples/custom_limits.nim

import std/[os, options]
import gzfast

proc main() =
  if paramCount() != 1:
    quit("usage: custom_limits FILE.gz", 2)
  var config = defaultGzFastConfig()
  config.threads = 4
  config.outputLimit = some(1024'u64 * 1024 * 1024) # refuse > 1 GiB
  config.maxHeaderSize = 64 * 1024

  let decoder = initGzFastDecoder(config)
  let reader = decoder.open(paramStr(1))
  defer: reader.close()
  var buf = newString(64 * 1024)
  var total = 0'u64
  try:
    while true:
      let n = reader.readData(addr buf[0], buf.len)
      if n == 0: break
      total += n.uint64
    echo "decoded ", total, " bytes within limits"
  except GzFastError as e:
    if e.kind == geOutputLimit:
      stderr.writeLine("output limit exceeded; refusing to continue")
      quit(1)
    raise

main()

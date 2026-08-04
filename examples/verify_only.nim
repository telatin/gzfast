## Verify a gzip file without keeping its output.
##
## Compile from the checkout:
## nim c -d:release --threads:on -p:src examples/verify_only.nim

import std/os
import gzfast

proc main() =
  if paramCount() != 1:
    quit("usage: verify_only FILE.gz", 2)
  let reader = openGzFast(paramStr(1))
  defer: reader.close()
  try:
    # finish() decodes and verifies the complete compressed stream
    # without requiring the caller to consume the output.
    let report = reader.finish()
    echo "OK: ", report.memberCount, " member(s), ",
         report.decompressedBytes, " decoded bytes verified"
  except GzFastError as e:
    stderr.writeLine("corrupt: ", e.msg,
                     " (compressed offset ", e.compressedOffset,
                     ", member ", e.memberIndex, ")")
    quit(1)

main()

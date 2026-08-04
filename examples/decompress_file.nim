## Decompress a file to another file with a one-call API.
##
## Compile from the checkout:
## nim c -d:release --threads:on -p:src examples/decompress_file.nim

import std/os
import gzfast

proc main() =
  if paramCount() != 2:
    quit("usage: decompress_file IN.gz OUT", 2)
  let report = decompressFile(paramStr(1), paramStr(2))
  echo "decompressed ", report.decompressedBytes, " bytes from ",
       report.memberCount, " member(s); crcVerified=", report.crcVerified

main()

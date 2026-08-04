## Stream a FASTQ.gz file record by record.
##
## Compile from the checkout:
## nim c -d:release --threads:on -p:src examples/stream_fastq.nim

import std/os
import gzfast

proc main() =
  if paramCount() != 1:
    quit("usage: stream_fastq FILE.fastq.gz", 2)
  let input = openGzFast(paramStr(1), threads = 8)
  defer: input.close()

  var record: array[4, string]
  var idx = 0
  var records = 0
  var bases = 0
  for line in input.lines:
    record[idx] = line
    inc idx
    if idx == 4:
      idx = 0
      inc records
      bases += record[1].len
  # Reaching EOF means the whole compressed stream was verified.
  let report = input.finish()
  echo "records=", records, " bases=", bases,
       " members=", report.memberCount,
       " crcVerified=", report.crcVerified

main()

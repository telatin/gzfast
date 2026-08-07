## Generate deterministic local benchmark corpora without system tools.

import std/[os, strutils]
import ../tests/helpers/[fixtures, gzip_builder]

proc addTwoDigits(output: var string; value: int) =
  if value < 10:
    output.add('0')
  output.add($value)

proc makeLogText(targetBytes: int): string =
  let levels = ["INFO", "WARN", "DEBUG", "INFO", "ERROR", "INFO"]
  result = newStringOfCap(targetBytes + 256)
  var line = 0
  while result.len < targetBytes:
    result.add("2026-08-07T12:")
    result.addTwoDigits(line mod 60)
    result.add(":")
    result.addTwoDigits((line * 7) mod 60)
    result.add("Z level=")
    result.add(levels[line mod levels.len])
    result.add(" sample=S")
    result.add($(line mod 97))
    result.add(" lane=")
    result.add($((line mod 4) + 1))
    result.add(" reads=")
    result.add($((line * 7919) mod 1_000_000))
    result.add(" bytes=")
    result.add($((line * 104729) mod 10_000_000))
    result.add(" message=deterministic benchmark line\n")
    inc line
  result.setLen(targetBytes)

proc makePseudoRandom(targetBytes: int): string =
  result = newString(targetBytes)
  var state = 0x12345678'u32
  for i in 0 ..< targetBytes:
    state = state * 1664525'u32 + 1013904223'u32
    result[i] = chr(int((state shr 24) and 0xFF'u32))

when isMainModule:
  let outputDir = currentSourcePath().parentDir() / "generated"
  createDir(outputDir)
  writeFile(outputDir / "marker-multiblock-64m.gz",
            buildRepeatedBlocksGzip(384, 174763))
  writeFile(outputDir / "marker-fallback-64m.gz",
            buildRepeatedGzip(64'u64 * 1024 * 1024, markerCandidate = true))

  var bgzf: File
  doAssert open(bgzf, outputDir / "bgzf-repeated.gz", fmWrite)
  let bgzfUnit = readFixture("bgzf.gz")
  for _ in 0 ..< 512: bgzf.write(bgzfUnit)
  bgzf.close()

  var members: File
  doAssert open(members, outputDir / "members-10000.gz", fmWrite)
  let one = readFixture("one_byte.gz")
  for _ in 0 ..< 10000: members.write(one)
  members.close()

  let fastqRecord =
    "@SEQ0 synthetic benchmark record\n" &
    repeat("ACGT", 25) & "\n+\n" &
    repeat("I", 100) & "\n"
  let fastqTargetRecords = int((64'u64 * 1024 * 1024) div
                               uint64(fastqRecord.len))
  writeFile(outputDir / "fastq-single-64m.fastq.gz",
            buildRepeatedRecordGzip(fastqRecord, fastqTargetRecords))

  var fastqConcat: File
  doAssert open(fastqConcat,
                outputDir / "fastq-concat-64m.fastq.gz", fmWrite)
  let concatMembers = 64
  let recordsPerMember = max(1, fastqTargetRecords div concatMembers)
  for _ in 0 ..< concatMembers:
    fastqConcat.write(buildRepeatedRecordGzip(fastqRecord, recordsPerMember))
  fastqConcat.close()

  let recordsPerBgzfBlock = max(1, (64 * 1024) div fastqRecord.len)
  writeFile(outputDir / "fastq-bgzf-32m.bgzf.fastq.gz",
            buildRepeatedRecordBgzf(fastqRecord, recordsPerBgzfBlock, 512))

  const genericControlBytes = 8 * 1024 * 1024
  writeFile(outputDir / "log-lines-8m.log.gz",
            buildFixedLiteralGzip(makeLogText(genericControlBytes)))
  writeFile(outputDir / "stored-random-8m.gz",
            buildStoredGzip(makePseudoRandom(genericControlBytes)))

  echo outputDir

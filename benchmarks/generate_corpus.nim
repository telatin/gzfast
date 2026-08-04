## Generate deterministic local benchmark corpora without system tools.

import std/[os]
import ../tests/helpers/[fixtures, gzip_builder]

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

  echo outputDir

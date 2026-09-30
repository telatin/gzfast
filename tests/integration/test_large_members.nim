## Regression tests for concatenated gzip members whose decoded size exceeds
## `maxSpeculativeOutput` (default 16 MiB). gzfast 0.3.0 livelocked on these
## by re-scheduling the same rejected member batch forever instead of
## falling back to the sequential decoder.
##
## Fixtures are generated at test time with the gzfast writer from seeded
## synthetic FASTQ, so they compress realistically. The nimble task runs this
## binary under `run_with_timeout`; each case also checks its own wall clock.

import std/[monotimes, os, random, streams, strutils, times, unittest]
import gzfast
import gzfast/private/zlib_api

const
  MiB = 1024 * 1024
  BigMember = 20 * MiB
  SmallMember = 256 * 1024
  MaxDecodeSeconds = 10.0

type
  Fixture = object
    path: string
    members: int
    length: uint64
    crc: uint32

proc updateCrc(crc: var uint32; data: string) =
  if data.len > 0:
    crc = gzCrc32(crc, cast[ptr byte](unsafeAddr data[0]), csize_t(data.len))

proc fastqChunk(rng: var Rand; length: int): string =
  ## Seeded synthetic FASTQ, truncated to exactly `length` bytes. Reads are
  ## drawn from a small pool and qualities are low-entropy, so members
  ## compress roughly like real sequencing data.
  const bases = "ACGT"
  var pool, qualities: seq[string]
  for _ in 0 ..< 64:
    var read = newString(150)
    for i in 0 ..< read.len: read[i] = bases[rng.rand(3)]
    pool.add(read)
    var quality = newString(150)
    for i in 0 ..< quality.len:
      quality[i] = if rng.rand(15) == 0: '#' else: 'I'
    qualities.add(quality)
  result = newStringOfCap(length + 512)
  var index = 0
  while result.len < length:
    let read = pool[rng.rand(pool.high)][0 ..< 100 + rng.rand(50)]
    result.add("@read" & $index & "\n")
    result.add(read)
    result.add("\n+\n")
    result.add(qualities[rng.rand(qualities.high)][0 ..< read.len])
    result.add('\n')
    inc index
  result.setLen(length)

proc buildMembers(name: string; sizes: openArray[int]; seed = 42): Fixture =
  result.path = getTempDir() / ("gzfast_large_members_" & name & ".gz")
  result.members = sizes.len
  var rng = initRand(seed)
  var writeConfig = defaultGzFastWriteConfig()
  writeConfig.level = 6
  var output: File
  doAssert open(output, result.path, fmWrite)
  defer: output.close()
  for size in sizes:
    let plain = rng.fastqChunk(size)
    let writer = openGzFastWriter(output, writeConfig)
    discard writer.writeString(plain)
    discard writer.finish()
    result.crc.updateCrc(plain)
    result.length += uint64(plain.len)

proc checkDecoded(fixture: Fixture; input: GzFastStream): DecodeReport =
  let started = getMonoTime()
  var buffer = newString(64 * 1024)
  var crc = 0'u32
  var total = 0'u64
  while true:
    let count = input.readData(addr buffer[0], buffer.len)
    if count == 0: break
    crc = gzCrc32(crc, cast[ptr byte](addr buffer[0]), csize_t(count))
    total += uint64(count)
  result = input.finish()
  let elapsed = (getMonoTime() - started).inMilliseconds.float / 1000
  check elapsed < MaxDecodeSeconds
  check total == fixture.length
  check crc == fixture.crc
  check result.decompressedBytes == fixture.length
  check result.memberCount == uint64(fixture.members)
  check result.crcVerified

proc decodePath(fixture: Fixture; threads: int): DecodeReport =
  let input = openGzFast(fixture.path, threads = threads)
  defer: input.close()
  fixture.checkDecoded(input)

proc decodeStdinLike(fixture: Fixture): DecodeReport =
  let source = newFileStream(fixture.path, fmRead)
  doAssert not source.isNil
  defer: source.close()
  let input = openGzFastSequential(source)
  defer: input.close()
  fixture.checkDecoded(input)

var fixtures: seq[Fixture]

proc fixtureNamed(name: string): Fixture =
  for fixture in fixtures:
    if fixture.path.endsWith("_" & name & ".gz"):
      return fixture
  raise newException(KeyError, name)

fixtures.add buildMembers("big2", [BigMember, BigMember])
fixtures.add buildMembers("mixed", [SmallMember, BigMember, SmallMember])
block:
  var sizes = @[BigMember]
  for _ in 0 ..< 40: sizes.add(4 * 1024)
  fixtures.add buildMembers("bigfirst", sizes)
block:
  var sizes: seq[int]
  for _ in 0 ..< 50: sizes.add(320 * 1024)
  fixtures.add buildMembers("small50", sizes)

suite "concatenated members larger than maxSpeculativeOutput":
  for name in ["big2", "mixed", "bigfirst", "small50"]:
    for threads in [0, 4]:
      test name & " threads=" & $threads:
        discard fixtureNamed(name).decodePath(threads)

    test name & " sequential stream":
      let report = fixtureNamed(name).decodeStdinLike()
      check report.pathsUsed == {dpSequential}

  test "big members enter the parallel path, then fall back to sequential":
    # Guards the fixture itself: if the members stop being detected as
    # multi-member, the tests above no longer exercise the livelock.
    let report = fixtureNamed("big2").decodePath(4)
    check dpMultiMember in report.pathsUsed
    check dpSequential in report.pathsUsed

  test "small members stay on the parallel member path":
    let report = fixtureNamed("small50").decodePath(4)
    check report.pathsUsed == {dpMultiMember}

when defined(keepFixtures):
  for fixture in fixtures: echo fixture.path, " ", getFileSize(fixture.path)
else:
  for fixture in fixtures: removeFile(fixture.path)

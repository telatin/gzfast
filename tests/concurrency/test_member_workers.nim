## Milestone 5 independent gzip/BGZF member worker tests.

import std/[os, unittest]
import gzfast/[buffers, config]
import gzfast/gzip/members
import gzfast/private/zlib_api
import gzfast/scheduler/[bounded_queue, controller, jobs]
import ../helpers/fixtures

proc releaseResult(result: var JobResult) =
  if not result.output.data.isNil:
    result.output.release(boCoordinator)

suite "independent member workers":
  test "BGZF blocks decode and verify independently":
    let fixture = fixtureByName("bgzf.gz")
    let runtime = initMemberRuntime(fixturePath(fixture.name),
      defaultGzFastConfig(), workerCount = 4, queueCapacity = 8,
      reorderCapacity = 8)
    defer: runtime.deinit()
    var offset = 0'u64
    var ordinal = 0'u64
    while offset < runtime.source.size:
      let header = runtime.source.parseHeaderAt(offset, 1024 * 1024)
      check header.status == hasOk
      check header.info.bgzfBlockSize > 0
      let next = offset + uint64(header.info.bgzfBlockSize)
      check runtime.submit(DecodeJob(
        ordinal: ordinal, kind: jkDecodeBgzfGroup,
        compressedStart: offset, compressedEnd: next,
        knownEnd: next, authoritative: true)) == qsOk
      offset = next
      inc ordinal
    runtime.closeAdmission()

    var total = 0'u64
    var crc = 0'u32
    for expected in 0'u64 ..< ordinal:
      var result: JobResult
      check runtime.nextOrdered(result) == rnsOk
      check result.ordinal == expected
      check result.status == jrsOk
      check result.memberEnd == result.compressedEnd
      if result.output.length > 0:
        crc = gzCrc32(crc, cast[ptr byte](result.output.data),
                      csize_t(result.output.length))
      total += result.decodedLength
      result.releaseResult()
    runtime.joinWorkers()
    check total == fixture.length
    check crc == fixture.crc32
    check runtime.workerStats().peak >= 2
    check runtime.allocations().currentBytes == 0

  test "ordinary concatenated members decode in parallel":
    let fixture = fixtureByName("concat_3.gz")
    let runtime = initMemberRuntime(fixturePath(fixture.name),
      defaultGzFastConfig(), workerCount = 3, queueCapacity = 8,
      reorderCapacity = 8)
    defer: runtime.deinit()
    let candidates = runtime.source.scanHeaderCandidates(
      0, runtime.source.size, 1024 * 1024, 8)
    check candidates.len == 3
    for ordinal, offset in candidates:
      check runtime.submit(DecodeJob(
        ordinal: uint64(ordinal), kind: jkDecodeMember,
        compressedStart: offset, authoritative: ordinal == 0,
        delayMs: (candidates.len - ordinal) * 3)) == qsOk
    runtime.closeAdmission()

    var expectedStart = 0'u64
    var accepted = 0
    var total = 0'u64
    var crc = 0'u32
    for ordinal in 0 ..< candidates.len:
      var result: JobResult
      check runtime.nextOrdered(result) == rnsOk
      check result.ordinal == uint64(ordinal)
      check result.status == jrsOk
      check result.compressedStart == expectedStart
      expectedStart = result.memberEnd
      inc accepted
      total += result.decodedLength
      if result.output.length > 0:
        crc = gzCrc32(crc, cast[ptr byte](result.output.data),
                      csize_t(result.output.length))
      result.releaseResult()
    runtime.joinWorkers()
    check expectedStart == runtime.source.size
    check accepted == 3
    check total == fixture.length
    check crc == fixture.crc32
    check runtime.allocations().currentBytes == 0

  test "authoritative checksum failure is a plain error result":
    var bytes = toBytes(readFixture("small_text.gz"))
    bytes[^8] = bytes[^8] xor 0x80
    let path = getTempDir() / "gzfast_member_bad_crc.gz"
    writeFile(path, toString(bytes))
    defer: removeFile(path)
    let runtime = initMemberRuntime(path, defaultGzFastConfig(), 1, 2, 2)
    defer: runtime.deinit()
    check runtime.submit(DecodeJob(ordinal: 0, kind: jkDecodeMember,
      compressedStart: 0, authoritative: true)) == qsOk
    runtime.closeAdmission()
    var result: JobResult
    check runtime.nextOrdered(result) == rnsOk
    check result.status == jrsError
    check result.error.kind == weChecksum
    check result.output.data.isNil
    runtime.joinWorkers()
    check runtime.allocations().currentBytes == 0

  test "output cap rejects oversized members without leaking":
    var config = defaultGzFastConfig()
    config.maxSpeculativeOutput = 1024
    let runtime = initMemberRuntime(fixturePath("repetitive.gz"), config,
      1, 2, 2)
    defer: runtime.deinit()
    check runtime.submit(DecodeJob(ordinal: 0, kind: jkDecodeMember,
      compressedStart: 0, authoritative: true)) == qsOk
    runtime.closeAdmission()
    var result: JobResult
    check runtime.nextOrdered(result) == rnsOk
    check result.status == jrsRejected
    check result.error.kind == weOutputCap
    check result.output.data.isNil
    runtime.joinWorkers()
    check runtime.allocations().currentBytes == 0

  test "valid gzip magic inside an earlier member is not authoritative":
    let inner = readFixture("one_byte.gz")
    let outer = readFixture("small_text.gz")
    # Add an XY extra subfield containing a complete valid gzip member.
    var combined = newStringOfCap(outer.len + inner.len + 6)
    combined.add outer[0 .. 2]
    combined.add char(0x04) # FEXTRA
    combined.add outer[4 .. 9]
    let xlen = inner.len + 4
    combined.add char(xlen and 0xFF)
    combined.add char((xlen shr 8) and 0xFF)
    combined.add "XY"
    combined.add char(inner.len and 0xFF)
    combined.add char((inner.len shr 8) and 0xFF)
    combined.add inner
    combined.add outer[10 .. ^1]
    let path = getTempDir() / "gzfast_false_member_candidate.gz"
    writeFile(path, combined)
    defer: removeFile(path)

    let runtime = initMemberRuntime(path, defaultGzFastConfig(), 2, 4, 4)
    defer: runtime.deinit()
    let candidates = runtime.source.scanHeaderCandidates(
      0, runtime.source.size, 1024 * 1024, 4)
    check candidates.len == 2
    check candidates[0] == 0
    check candidates[1] > 0
    for ordinal, offset in candidates:
      check runtime.submit(DecodeJob(ordinal: uint64(ordinal),
        kind: jkDecodeMember, compressedStart: offset,
        authoritative: ordinal == 0,
        delayMs: if ordinal == 0: 20 else: 0)) == qsOk
    runtime.closeAdmission()
    var outerResult, falseCandidate: JobResult
    check runtime.nextOrdered(outerResult) == rnsOk
    check outerResult.status == jrsOk
    check outerResult.memberEnd == runtime.source.size
    check runtime.nextOrdered(falseCandidate) == rnsOk
    check falseCandidate.status == jrsOk # independently valid
    check falseCandidate.compressedStart < outerResult.memberEnd
    # Coordinator/path selection discards it because it is inside the
    # authoritative predecessor, despite being a valid gzip stream itself.
    outerResult.releaseResult()
    falseCandidate.releaseResult()
    runtime.joinWorkers()
    check runtime.allocations().currentBytes == 0

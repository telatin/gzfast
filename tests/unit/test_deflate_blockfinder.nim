## Block-header and bounded dynamic-candidate finder tests.

import std/unittest
import gzfast/source
import gzfast/deflate/[bitreader, block_header, blockfinder, dynamic_header]
import ../helpers/deflate_bits

suite "DEFLATE block headers":
  test "all BFINAL and BTYPE combinations":
    for final in [false, true]:
      for kind in 0 .. 3:
        var writer: TestBitWriter
        writer.addBits(if final: 1 else: 0, 1)
        writer.addBits(uint32(kind), 2)
        let owner = openMemoryReadAtSource(writer.bytes())
        defer: owner.close()
        var reader = initBitReader(owner.view)
        var header: DeflateBlockHeader
        check reader.tryReadBlockHeader(header)
        check header.final == final
        check ord(header.blockType) == kind
        check header.startBit == 0
        check header.payloadHeaderBit == 3

suite "dynamic block finder":
  test "finds structurally valid non-final header at arbitrary offsets":
    for prefix in 0 .. 15:
      var writer: TestBitWriter
      writer.addBits(0xFFFF, prefix)
      writer.addMinimalDynamicHeader(final = false)
      let owner = openMemoryReadAtSource(writer.bytes())
      defer: owner.close()
      let workspace = newDynamicHeaderWorkspace()
      var candidate: DynamicCandidate
      check findNextDynamicCandidate(owner.view, uint64(prefix),
        uint64(writer.bitLength), workspace, candidate, pageSize = 1)
      check candidate.startBit == uint64(prefix)
      check candidate.headerEndBit > candidate.startBit
      check candidate.literalCount == 257
      check candidate.distanceCount == 1

  test "final dynamic block is deliberately not a candidate":
    var writer: TestBitWriter
    writer.addMinimalDynamicHeader(final = true)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var candidate: DynamicCandidate
    check not findNextDynamicCandidate(owner.view, 0,
      uint64(writer.bitLength), newDynamicHeaderWorkspace(), candidate)

  test "malformed dynamic tree is rejected":
    var writer: TestBitWriter
    writer.addMinimalDynamicHeader(final = false, overflowLastRepeat = true)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var candidate: DynamicCandidate
    check not findNextDynamicCandidate(owner.view, 0,
      uint64(writer.bitLength), newDynamicHeaderWorkspace(), candidate,
      pageSize = 2)

  test "search limits are strict and bounded":
    var writer: TestBitWriter
    writer.addBits(0, 11)
    writer.addMinimalDynamicHeader(final = false)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    let workspace = newDynamicHeaderWorkspace()
    var candidate: DynamicCandidate
    check not findNextDynamicCandidate(owner.view, 0, 11,
      workspace, candidate)
    check findNextDynamicCandidate(owner.view, 11,
      uint64(writer.bitLength), workspace, candidate)
    check candidate.startBit == 11

  test "random bytes do not make invalid candidate authoritative":
    var data = newSeq[byte](4096)
    var state = 0x12345678'u32
    for i in 0 ..< data.len:
      state = state * 1664525'u32 + 1013904223'u32
      data[i] = byte(state shr 24)
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    var candidate: DynamicCandidate
    let found = findNextDynamicCandidate(owner.view, 0,
      uint64(data.len * 8), newDynamicHeaderWorkspace(), candidate,
      pageSize = 31)
    if found:
      # Structural validation is all the finder promises. The result is
      # bounded and remains non-authoritative until complete decode.
      check candidate.startBit < uint64(data.len * 8)
      check candidate.headerEndBit > candidate.startBit

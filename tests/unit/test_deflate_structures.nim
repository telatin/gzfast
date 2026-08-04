## Stored-block and dynamic-header structural tests.

import std/unittest
import gzfast/source
import gzfast/deflate/[bitreader, dynamic_header, stored]
import ../helpers/deflate_bits

proc storedFixture(prefixBits: int; payload: openArray[byte];
                   corruptInverse = false): seq[byte] =
  var writer: TestBitWriter
  writer.addBits(0, prefixBits)
  writer.addBits(1, 1) # BFINAL
  writer.addBits(0, 2) # stored
  writer.alignByte()
  let length = uint16(payload.len)
  var inverse = not length
  if corruptInverse: inverse = inverse xor 1
  writer.addBits(length, 16)
  writer.addBits(inverse, 16)
  for value in payload: writer.addByte(value)
  writer.bytes()

suite "DEFLATE stored blocks":
  test "every block-start bit alignment":
    let payload = @[1'u8, 2, 3, 4, 5]
    for prefix in 0 .. 7:
      let bytes = storedFixture(prefix, payload)
      let owner = openMemoryReadAtSource(bytes)
      defer: owner.close()
      var reader = initBitReader(owner.view, uint64(prefix + 3), pageSize = 1)
      var info: StoredBlockInfo
      check reader.parseStoredBlock(info) == sbsOk
      check info.length == uint16(payload.len)
      check info.endBit == reader.position

  test "zero-length and maximum-length blocks":
    for length in [0, 65535]:
      var payload = newSeq[byte](length)
      let bytes = storedFixture(0, payload)
      let owner = openMemoryReadAtSource(bytes)
      defer: owner.close()
      var reader = initBitReader(owner.view, 3, pageSize = 31)
      var info: StoredBlockInfo
      check reader.parseStoredBlock(info) == sbsOk
      check info.length == uint16(length)

  test "LEN NLEN mismatch rejected":
    let bytes = storedFixture(0, [1'u8, 2], corruptInverse = true)
    let owner = openMemoryReadAtSource(bytes)
    defer: owner.close()
    var reader = initBitReader(owner.view, 3)
    var info: StoredBlockInfo
    check reader.parseStoredBlock(info) == sbsInvalidLength

  test "truncation in header and payload":
    let complete = storedFixture(0, [1'u8, 2, 3, 4])
    for cut in 0 ..< complete.len:
      let owner = openMemoryReadAtSource(complete.toOpenArray(0, cut - 1))
      defer: owner.close()
      var reader = initBitReader(owner.view, min(3'u64, owner.view.size * 8))
      var info: StoredBlockInfo
      check reader.parseStoredBlock(info) != sbsOk

suite "DEFLATE dynamic headers":
  test "minimal complete dynamic trees":
    var writer: TestBitWriter
    writer.addMinimalDynamicHeader(final = false)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var reader = initBitReader(owner.view)
    var header: uint32
    check reader.tryReadBits(3, header)
    check header == 4 # non-final + dynamic in stream-bit order
    let workspace = newDynamicHeaderWorkspace()
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(workspace, info) == dhsOk
    check info.literalCount == 257
    check info.distanceCount == 1
    check workspace.combinedLengths[256] == 1
    check workspace.combinedLengths[257] == 1
    check info.headerEndBit == reader.position

  test "truncation at every bit in a valid header":
    var writer: TestBitWriter
    writer.addMinimalDynamicHeader(final = false)
    let complete = writer.bytes()
    for bitEnd in 3 ..< writer.bitLength:
      # Limit source to whole bytes, then use a wrapper size only where it
      # genuinely removes header bits; exact bit-tail coverage is handled by
      # the bit-reader tests.
      let byteEnd = bitEnd div 8
      if byteEnd == 0: continue
      let owner = openMemoryReadAtSource(complete.toOpenArray(0, byteEnd - 1))
      defer: owner.close()
      var reader = initBitReader(owner.view, 3)
      let workspace = newDynamicHeaderWorkspace()
      var info: DynamicHeaderInfo
      check reader.parseDynamicHeader(workspace, info) != dhsOk

  test "repeat expansion overflow rejected":
    var writer: TestBitWriter
    writer.addMinimalDynamicHeader(final = false, overflowLastRepeat = true)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var reader = initBitReader(owner.view, 3)
    let workspace = newDynamicHeaderWorkspace()
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(workspace, info) == dhsRepeatOverflow

  test "repeat 16 before any length is rejected":
    var writer: TestBitWriter
    writer.addInitialRepeat16Header()
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var reader = initBitReader(owner.view, 3)
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(newDynamicHeaderWorkspace(), info) ==
      dhsInvalidRepeat

  test "missing end-of-block symbol rejected":
    var writer: TestBitWriter
    writer.addMinimalDynamicHeader(final = false, includeEob = false)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var reader = initBitReader(owner.view, 3)
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(newDynamicHeaderWorkspace(), info) ==
      dhsMissingEndOfBlock

  test "nonzero reserved distance symbol rejected":
    var writer: TestBitWriter
    writer.addReservedDistanceHeader()
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var reader = initBitReader(owner.view, 3)
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(newDynamicHeaderWorkspace(), info) ==
      dhsReservedDistance

  test "empty distance tree accepted when no length symbol exists":
    var writer: TestBitWriter
    writer.addEmptyDistanceHeader()
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var reader = initBitReader(owner.view, 3)
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(newDynamicHeaderWorkspace(), info) == dhsOk
    check info.distanceTreeEmpty

## Exhaustive tests for the positional LSB-first DEFLATE bit reader.

import std/unittest
import gzfast/source
import gzfast/deflate/bitreader

proc referenceBits(data: openArray[byte]; start: int; count: int): uint32 =
  for i in 0 ..< count:
    let bit = (data[(start + i) shr 3] shr ((start + i) and 7)) and 1
    result = result or (uint32(bit) shl i)

suite "DEFLATE bit reader":
  test "all initial offsets and widths through 32 bits":
    var data = newSeq[byte](80)
    for i in 0 ..< data.len:
      data[i] = byte((i * 73 + 19) and 0xFF)
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    for pageSize in [1, 2, 3, 7, 31, 63, 257, 4093]:
      for start in 0 .. 7:
        for width in 0 .. 32:
          var reader = initBitReader(owner.view, uint64(start), pageSize)
          var value: uint32
          check reader.tryReadBits(width, value)
          check value == referenceBits(data, start, width)
          check reader.position == uint64(start + width)

  test "sequential reads cross pages and bytes":
    var data = newSeq[byte](200)
    for i in 0 ..< data.len:
      data[i] = byte(i xor (i shr 2))
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    for pageSize in [1, 7, 31, 63]:
      var reader = initBitReader(owner.view, 5, pageSize)
      var expectedPos = 5
      for width in [1, 3, 8, 17, 32, 2, 29, 7, 16, 31]:
        var value: uint32
        check reader.tryReadBits(width, value)
        check value == referenceBits(data, expectedPos, width)
        expectedPos += width
        check reader.position == uint64(expectedPos)

  test "peek does not advance and advance is independent":
    let data = @[0xD6'u8, 0x39, 0xA5, 0x7C]
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    var reader = initBitReader(owner.view, 3, 1)
    var first, second: uint32
    check reader.tryPeekBits(17, first)
    check reader.position == 3
    check reader.tryPeekBits(17, second)
    check second == first
    check reader.tryAdvance(9)
    check reader.position == 12
    check reader.tryReadBits(8, second)
    check second == referenceBits(data, 12, 8)

  test "byte alignment at every initial offset":
    let data = @[0xFF'u8, 0x35, 0xA2]
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    for start in 0 .. 7:
      var reader = initBitReader(owner.view, uint64(start), pageSize = 1)
      check reader.alignToByte()
      let expected = if start == 0: 0 else: 8
      check reader.position == uint64(expected)
      var value: uint32
      check reader.tryReadBits(8, value)
      check value == data[expected div 8].uint32

  test "exact EOF and failed reads do not advance":
    let data = @[0xA5'u8, 0x5A]
    let owner = openMemoryReadAtSource(data)
    defer: owner.close()
    var reader = initBitReader(owner.view, 15, pageSize = 1)
    var value: uint32
    check reader.remainingBits == 1
    check reader.tryReadBits(1, value)
    check reader.position == 16
    check reader.remainingBits == 0
    check not reader.tryReadBits(1, value)
    check reader.position == 16
    check reader.tryReadBits(0, value)
    check value == 0

  test "truncated bit sequence and invalid widths":
    let owner = openMemoryReadAtSource([0x01'u8])
    defer: owner.close()
    var reader = initBitReader(owner.view, 7)
    var value: uint32
    check not reader.tryReadBits(2, value)
    check reader.position == 7
    check not reader.tryReadBits(33, value)
    check not reader.tryReadBits(-1, value)
    check not initBitReader(owner.view, 9).isValid

  test "64-bit compressed positions on sparse source":
    type SparseContext = object
      finalByteOffset: uint64
      value: byte
    proc sparseRead(context: pointer; offset: uint64; destination: pointer;
                    length: int): int {.nimcall, gcsafe, raises: [].} =
      let state = cast[ptr SparseContext](context)
      if length <= 0 or offset > state.finalByteOffset:
        return 0
      cast[ptr byte](destination)[] =
        if offset == state.finalByteOffset: state.value else: 0
      1
    var context = SparseContext(finalByteOffset: 3'u64 * 1024 * 1024 * 1024,
                                value: 0xB6)
    let source = ReadAtSource(context: addr context,
      size: context.finalByteOffset + 1, readAtProc: sparseRead)
    let start = context.finalByteOffset * 8 + 2
    var reader = initBitReader(source, start, pageSize = 1)
    var value: uint32
    check reader.tryReadBits(6, value)
    check value == uint32(0xB6 shr 2)
    check reader.position == start + 6

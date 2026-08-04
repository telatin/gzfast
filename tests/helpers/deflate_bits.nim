## Deterministic LSB-first fixture builder for pure DEFLATE tests.

type TestBitWriter* = object
  bits: seq[byte]

proc addBits*(writer: var TestBitWriter; value: uint32; count: int) =
  for i in 0 ..< count:
    writer.bits.add(byte((value shr i) and 1))

proc alignByte*(writer: var TestBitWriter) =
  while (writer.bits.len and 7) != 0:
    writer.bits.add(0)

proc addByte*(writer: var TestBitWriter; value: byte) =
  writer.addBits(value, 8)

proc bytes*(writer: TestBitWriter): seq[byte] =
  result.setLen((writer.bits.len + 7) div 8)
  for i, bit in writer.bits:
    result[i shr 3] = result[i shr 3] or (bit shl (i and 7))

proc bitLength*(writer: TestBitWriter): int = writer.bits.len

proc reverseBits(value: uint32; count: int): uint32 =
  for i in 0 ..< count:
    result = (result shl 1) or ((value shr i) and 1)

proc addFixedSymbol*(writer: var TestBitWriter; symbol: int) =
  var code: uint32
  var length: int
  if symbol <= 143:
    code = uint32(0x30 + symbol); length = 8
  elif symbol <= 255:
    code = uint32(0x190 + symbol - 144); length = 9
  elif symbol <= 279:
    code = uint32(symbol - 256); length = 7
  else:
    code = uint32(0xC0 + symbol - 280); length = 8
  writer.addBits(reverseBits(code, length), length)

proc addFixedDistance*(writer: var TestBitWriter; symbol: int) =
  writer.addBits(reverseBits(uint32(symbol), 5), 5)

proc addFixedBlockHeader*(writer: var TestBitWriter; final: bool) =
  writer.addBits(if final: 1 else: 0, 1)
  writer.addBits(1, 2)

proc addMinimalDynamicHeader*(writer: var TestBitWriter;
                              final: bool; includeEob = true;
                              overflowLastRepeat = false) =
  ## Dynamic block with precode symbols 1 and 18. Literal alphabet has
  ## only EOB length 1; distance symbol zero has length 1.
  writer.addBits(if final: 1 else: 0, 1)
  writer.addBits(2, 2) # dynamic
  writer.addBits(0, 5) # HLIT = 257
  writer.addBits(0, 5) # HDIST = 1
  writer.addBits(14, 4) # HCLEN = 18, includes symbol 1
  for index in 0 ..< 18:
    let symbol = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1][index]
    writer.addBits(if symbol in {1, 18}: 1 else: 0, 3)
  # Canonical one-bit codes: symbol 1 -> 0, symbol 18 -> 1.
  writer.addBits(1, 1)
  writer.addBits(127, 7) # 138 zeros
  writer.addBits(1, 1)
  writer.addBits(if overflowLastRepeat: 110
                 elif includeEob: 107
                 else: 108, 7) # 118 or 119 zeros
  if includeEob:
    writer.addBits(0, 1) # EOB length 1
  writer.addBits(0, 1) # distance symbol zero length 1

proc addInitialRepeat16Header*(writer: var TestBitWriter) =
  writer.addBits(0, 1)
  writer.addBits(2, 2)
  writer.addBits(0, 5)
  writer.addBits(0, 5)
  writer.addBits(14, 4)
  for index in 0 ..< 18:
    let symbol = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1][index]
    writer.addBits(if symbol in {1, 16}: 1 else: 0, 3)
  # Canonical codes: symbol 1 -> 0, symbol 16 -> 1.
  writer.addBits(1, 1)

proc addReservedDistanceHeader*(writer: var TestBitWriter) =
  writer.addBits(0, 1)
  writer.addBits(2, 2)
  writer.addBits(0, 5)  # 257 literals
  writer.addBits(30, 5) # 31 distances, including reserved symbol 30
  writer.addBits(14, 4)
  for index in 0 ..< 18:
    let symbol = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1][index]
    writer.addBits(if symbol in {1, 18}: 1 else: 0, 3)
  writer.addBits(1, 1); writer.addBits(127, 7) # 138 zero literals
  writer.addBits(1, 1); writer.addBits(107, 7) # 118 zero literals
  writer.addBits(0, 1)                         # EOB length one
  writer.addBits(1, 1); writer.addBits(19, 7) # 30 zero distances
  writer.addBits(0, 1)                         # reserved distance length one

proc addEmptyDistanceHeader*(writer: var TestBitWriter) =
  writer.addBits(0, 1)
  writer.addBits(2, 2)
  writer.addBits(0, 5)
  writer.addBits(0, 5)
  writer.addBits(14, 4)
  # precode: symbol 18 length 1; symbols 0 and 1 length 2
  for index in 0 ..< 18:
    let symbol = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1][index]
    let length = if symbol == 18: 1 elif symbol in {0, 1}: 2 else: 0
    writer.addBits(uint32(length), 3)
  writer.addBits(0, 1); writer.addBits(127, 7) # symbol 18, 138 zeros
  writer.addBits(0, 1); writer.addBits(107, 7) # symbol 18, 118 zeros
  writer.addBits(3, 2)                         # symbol 1, EOB length one
  writer.addBits(1, 2)                         # symbol 0, empty distance tree

## Canonical DEFLATE Huffman construction and allocation-free decode.

import ./bitreader, ./constants

const
  HuffmanTableSize* = 1 shl MaxCodeBits
  InvalidHuffmanEntry* = high(uint16)
  SymbolMask = 0x01FF'u16

type
  HuffmanBuildStatus* = enum
    hbsOk
    hbsEmpty
    hbsLengthTooLong
    hbsSymbolTooLarge
    hbsOversubscribed
    hbsIncomplete
    hbsCollision

  HuffmanTable* = object
    entries: array[HuffmanTableSize, uint16]
    maximumLength*: uint8
    symbolCount*: uint16

proc reverseLowBits*(value: uint32; count: int): uint32 =
  for i in 0 ..< count:
    result = (result shl 1) or ((value shr i) and 1)

proc clear(table: var HuffmanTable) =
  let used = if table.maximumLength == 0: 0
             else: 1 shl int(table.maximumLength)
  for i in 0 ..< used:
    table.entries[i] = InvalidHuffmanEntry
  table.maximumLength = 0
  table.symbolCount = 0

proc buildHuffman*(table: var HuffmanTable; lengths: openArray[uint8];
                   allowEmpty = false): HuffmanBuildStatus =
  table.clear()
  var counts: array[MaxCodeBits + 1, int]
  var maximum = 0
  var used = 0
  for symbol, lengthByte in lengths:
    let length = int(lengthByte)
    if length > MaxCodeBits:
      return hbsLengthTooLong
    if length != 0:
      if symbol > int(SymbolMask):
        return hbsSymbolTooLarge
      inc counts[length]
      inc used
      maximum = max(maximum, length)
  if used == 0:
    return if allowEmpty: hbsOk else: hbsEmpty

  var remaining = 1
  for length in 1 .. MaxCodeBits:
    remaining = remaining * 2 - counts[length]
    if remaining < 0:
      return hbsOversubscribed
  if remaining != 0 and not (used == 1 and counts[1] == 1):
    return hbsIncomplete

  table.maximumLength = uint8(maximum)
  table.symbolCount = uint16(used)
  let tableSize = 1 shl maximum
  for i in 0 ..< tableSize:
    table.entries[i] = InvalidHuffmanEntry

  var nextCode: array[MaxCodeBits + 1, uint32]
  var code = 0'u32
  for bits in 1 .. MaxCodeBits:
    code = (code + uint32(counts[bits - 1])) shl 1
    nextCode[bits] = code

  for symbol, lengthByte in lengths:
    let length = int(lengthByte)
    if length == 0:
      continue
    let reversed = reverseLowBits(nextCode[length], length)
    inc nextCode[length]
    let packed = (uint16(length) shl 9) or uint16(symbol)
    let repetitions = 1 shl (maximum - length)
    for suffix in 0 ..< repetitions:
      let index = int(reversed) or (suffix shl length)
      if table.entries[index] != InvalidHuffmanEntry:
        table.clear()
        return hbsCollision
      table.entries[index] = packed
  hbsOk

proc tryDecode*(table: HuffmanTable; reader: var BitReader;
                symbol: var uint16): bool =
  if table.maximumLength == 0:
    return false
  var bits: uint32
  var available: int
  if not reader.tryPeekBitsPadded(int(table.maximumLength), bits, available):
    return false
  let entry = table.entries[int(bits)]
  if entry == InvalidHuffmanEntry:
    return false
  let length = int(entry shr 9)
  if length == 0 or length > available or not reader.tryAdvance(length):
    return false
  symbol = entry and SymbolMask
  true

proc fixedLiteralLengths*(): array[FixedLiteralCodes, uint8] =
  for symbol in 0 .. 143: result[symbol] = 8
  for symbol in 144 .. 255: result[symbol] = 9
  for symbol in 256 .. 279: result[symbol] = 7
  for symbol in 280 .. 287: result[symbol] = 8

proc fixedDistanceLengths*(): array[MaxDistanceCodes, uint8] =
  for symbol in 0 ..< MaxDistanceCodes: result[symbol] = 5

proc buildFixedTrees*(literal, distance: var HuffmanTable): bool =
  let literalLengths = fixedLiteralLengths()
  let distanceLengths = fixedDistanceLengths()
  literal.buildHuffman(literalLengths) == hbsOk and
    distance.buildHuffman(distanceLengths) == hbsOk

## RFC 1951 dynamic Huffman header parser with fixed reusable storage.

import ./bitreader, ./constants, ./huffman

type
  DynamicHeaderStatus* = enum
    dhsOk
    dhsUnexpectedEof
    dhsInvalidCounts
    dhsInvalidPrecode
    dhsInvalidRepeat
    dhsRepeatOverflow
    dhsMissingEndOfBlock
    dhsReservedDistance
    dhsInvalidLiteralTree
    dhsInvalidDistanceTree

  DynamicHeaderInfo* = object
    literalCount*: int
    distanceCount*: int
    precodeCount*: int
    headerEndBit*: uint64
    distanceTreeEmpty*: bool

  DynamicHeaderWorkspace* = ref object
    precodeLengths*: array[PrecodeSymbols, uint8]
    combinedLengths*: array[MaxCombinedCodeLengths, uint8]
    precode*: HuffmanTable
    literal*: HuffmanTable
    distance*: HuffmanTable

proc newDynamicHeaderWorkspace*(): DynamicHeaderWorkspace =
  new(result)

proc read(reader: var BitReader; count: int; value: var int): bool =
  var bits: uint32
  if not reader.tryReadBits(count, bits):
    return false
  value = int(bits)
  true

proc parseDynamicHeader*(reader: var BitReader;
                         workspace: DynamicHeaderWorkspace;
                         info: var DynamicHeaderInfo): DynamicHeaderStatus =
  ## Parse fields beginning immediately after BFINAL/BTYPE.
  if workspace.isNil:
    return dhsInvalidPrecode
  for i in 0 ..< PrecodeSymbols:
    workspace.precodeLengths[i] = 0
  for i in 0 ..< MaxCombinedCodeLengths:
    workspace.combinedLengths[i] = 0

  var delta: int
  if not reader.read(5, delta): return dhsUnexpectedEof
  info.literalCount = 257 + delta
  if not reader.read(5, delta): return dhsUnexpectedEof
  info.distanceCount = 1 + delta
  if not reader.read(4, delta): return dhsUnexpectedEof
  info.precodeCount = 4 + delta
  if info.literalCount > MaxLiteralCodes or
     info.distanceCount > MaxDistanceCodes or
     info.precodeCount > PrecodeSymbols:
    return dhsInvalidCounts

  for i in 0 ..< info.precodeCount:
    var length: int
    if not reader.read(3, length): return dhsUnexpectedEof
    workspace.precodeLengths[int(PrecodeOrder[i])] = uint8(length)
  if workspace.precode.buildHuffman(workspace.precodeLengths) != hbsOk:
    return dhsInvalidPrecode

  let target = info.literalCount + info.distanceCount
  var used = 0
  while used < target:
    var symbol: uint16
    if not workspace.precode.tryDecode(reader, symbol):
      return if reader.remainingBits == 0: dhsUnexpectedEof
             else: dhsInvalidPrecode
    case symbol
    of 0'u16 .. 15'u16:
      workspace.combinedLengths[used] = uint8(symbol)
      inc used
    of 16'u16:
      if used == 0:
        return dhsInvalidRepeat
      var extra: int
      if not reader.read(2, extra): return dhsUnexpectedEof
      let repeat = 3 + extra
      if repeat > target - used:
        return dhsRepeatOverflow
      let previous = workspace.combinedLengths[used - 1]
      for i in 0 ..< repeat:
        workspace.combinedLengths[used + i] = previous
      used += repeat
    of 17'u16:
      var extra: int
      if not reader.read(3, extra): return dhsUnexpectedEof
      let repeat = 3 + extra
      if repeat > target - used:
        return dhsRepeatOverflow
      used += repeat # storage is already zeroed
    of 18'u16:
      var extra: int
      if not reader.read(7, extra): return dhsUnexpectedEof
      let repeat = 11 + extra
      if repeat > target - used:
        return dhsRepeatOverflow
      used += repeat
    else:
      return dhsInvalidPrecode

  if workspace.combinedLengths[EndOfBlockSymbol] == 0:
    return dhsMissingEndOfBlock
  if info.distanceCount > 30:
    for index in 30 ..< info.distanceCount:
      if workspace.combinedLengths[info.literalCount + index] != 0:
        return dhsReservedDistance

  if workspace.literal.buildHuffman(
      workspace.combinedLengths.toOpenArray(0, info.literalCount - 1)) != hbsOk:
    return dhsInvalidLiteralTree

  var hasLengthSymbol = false
  for index in 257 ..< info.literalCount:
    if workspace.combinedLengths[index] != 0:
      hasLengthSymbol = true
      break
  let distanceStatus = workspace.distance.buildHuffman(
    workspace.combinedLengths.toOpenArray(info.literalCount,
      info.literalCount + info.distanceCount - 1), allowEmpty = true)
  info.distanceTreeEmpty = workspace.distance.symbolCount == 0
  if distanceStatus != hbsOk or (hasLengthSymbol and info.distanceTreeEmpty):
    return dhsInvalidDistanceTree

  info.headerEndBit = reader.position
  dhsOk

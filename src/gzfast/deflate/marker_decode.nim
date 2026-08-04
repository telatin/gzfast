## Scalar marker-aware DEFLATE decoder for unknown predecessor history.
##
## The virtual history is markers zero through 32767 followed by output.
## Only output symbols are stored. This preserves normal one-symbol-at-a-
## time overlap semantics without a duplicate uint16 history ring.

import ../buffers, ../source
import ./[bitreader, block_header, constants, dynamic_header, huffman]

const
  DeflateWindowSize* = 32768
  MarkerBase* = 32768'u16

type
  MarkerDecodeStatus* = enum
    mdsBoundary
    mdsStreamEnd
    mdsMarkerFreeBoundary
    mdsUnexpectedEof
    mdsInvalidBlockType
    mdsInvalidStoredLength
    mdsInvalidDynamicHeader
    mdsInvalidSymbol
    mdsInvalidDistance
    mdsOutputLimit

  MarkerBuffer* = object
    storage*: SharedBuffer
    count*: int
    markerCount*: int
    maximum*: int

  MarkerDecoderWorkspace* = ref object
    dynamic*: DynamicHeaderWorkspace
    fixedLiteral*: HuffmanTable
    fixedDistance*: HuffmanTable

  MarkerDecodeResult* = object
    status*: MarkerDecodeStatus
    startBit*: uint64
    endBit*: uint64
    output*: MarkerBuffer
    finalWindow*: array[DeflateWindowSize, byte]
    hasFinalWindow*: bool

proc newMarkerDecoderWorkspace*(): MarkerDecoderWorkspace =
  new(result)
  result.dynamic = newDynamicHeaderWorkspace()
  if not buildFixedTrees(result.fixedLiteral, result.fixedDistance):
    raise newException(Defect, "failed to construct fixed DEFLATE trees")

proc initMarkerBuffer*(maximumSymbols: int;
                       tracker: ptr AllocationTracker = nil): MarkerBuffer =
  if maximumSymbols < 0:
    raise newException(ValueError, "maximumSymbols must be nonnegative")
  result.maximum = maximumSymbols
  let initial = min(maximumSymbols, 64 * 1024)
  result.storage = allocSharedBuffer(initial, elementWidth = 2,
    owner = boWorker, tracker = tracker)

proc symbols(buffer: MarkerBuffer): ptr UncheckedArray[uint16] =
  cast[ptr UncheckedArray[uint16]](buffer.storage.data)

proc release*(buffer: var MarkerBuffer; expected = boWorker) =
  buffer.storage.release(expected)
  buffer = MarkerBuffer()

proc symbolAt*(buffer: MarkerBuffer; index: int): uint16 =
  if index < 0 or index >= buffer.count:
    raise newException(IndexDefect, "marker symbol index out of bounds")
  buffer.symbols[index]

proc isMarker*(symbol: uint16): bool = symbol >= MarkerBase
proc isLiteral*(symbol: uint16): bool = symbol <= 255
proc markerIndex*(symbol: uint16): int = int(symbol - MarkerBase)

proc ensureCapacity(buffer: var MarkerBuffer; needed: int): bool =
  if needed < 0 or needed > buffer.maximum:
    return false
  if needed > buffer.storage.capacity:
    try:
      buffer.storage.reserve(needed, buffer.maximum)
    except CatchableError:
      return false
  true

proc appendSymbol(buffer: var MarkerBuffer; symbol: uint16): bool =
  if not buffer.ensureCapacity(buffer.count + 1):
    return false
  buffer.symbols[buffer.count] = symbol
  inc buffer.count
  if symbol.isMarker: inc buffer.markerCount
  buffer.storage.setLength(buffer.count)
  true

proc appendLiteral*(buffer: var MarkerBuffer; value: byte): bool =
  buffer.appendSymbol(uint16(value))

proc copyMatch*(buffer: var MarkerBuffer; distance, length: int): bool =
  ## Bulk overlap-correct copy. Source runs are non-overlapping; once one
  ## period exists, geometric doubling reproduces byte-at-a-time semantics.
  if distance <= 0 or distance > DeflateWindowSize or length < 0 or
     length > buffer.maximum - buffer.count or
     not buffer.ensureCapacity(buffer.count + length):
    return false
  if length == 0: return true
  let data = buffer.symbols
  let matchStart = buffer.count
  var count = buffer.count
  var remaining = length
  var markers = buffer.markerCount

  if distance > matchStart:
    let fromWindow = min(distance - matchStart, remaining)
    let firstIndex = DeflateWindowSize + matchStart - distance
    if firstIndex < 0 or firstIndex + fromWindow > DeflateWindowSize:
      return false
    for i in 0 ..< fromWindow:
      data[count + i] = MarkerBase + uint16(firstIndex + i)
    count += fromWindow
    remaining -= fromWindow
    markers += fromWindow

  var generated = count - matchStart
  if remaining > 0 and generated < distance:
    let take = min(distance - generated, remaining)
    let sourceStart = count - distance
    if sourceStart < 0: return false
    for i in 0 ..< take:
      if data[sourceStart + i].isMarker: inc markers
    copyMem(addr data[count], addr data[sourceStart], take * sizeof(uint16))
    count += take
    remaining -= take
    generated += take

  while remaining > 0:
    let take = min(generated, remaining)
    for i in 0 ..< take:
      if data[matchStart + i].isMarker: inc markers
    copyMem(addr data[count], addr data[matchStart], take * sizeof(uint16))
    count += take
    remaining -= take
    generated += take

  buffer.count = count
  buffer.markerCount = markers
  buffer.storage.setLength(count)
  true

proc copyMatchScalar*(buffer: var MarkerBuffer; distance, length: int): bool =
  ## Retained correctness oracle for bulk-copy differential tests.
  if distance <= 0 or distance > DeflateWindowSize or length < 0 or
     length > buffer.maximum - buffer.count or
     not buffer.ensureCapacity(buffer.count + length):
    return false
  for _ in 0 ..< length:
    let sourceIndex = buffer.count - distance
    let symbol = if sourceIndex >= 0: buffer.symbols[sourceIndex]
      else: MarkerBase + uint16(DeflateWindowSize + sourceIndex)
    if not buffer.appendSymbol(symbol): return false
  true

proc markerFreeWindow*(buffer: MarkerBuffer;
                       window: var array[DeflateWindowSize, byte]): bool =
  if buffer.count < DeflateWindowSize:
    return false
  let start = buffer.count - DeflateWindowSize
  for i in 0 ..< DeflateWindowSize:
    let symbol = buffer.symbols[start + i]
    if not symbol.isLiteral:
      return false
    window[i] = byte(symbol)
  true

proc readBits(reader: var BitReader; count: int; value: var int): bool =
  var bits: uint32
  if not reader.tryReadBits(count, bits): return false
  value = int(bits)
  true

proc decodeStored(reader: var BitReader; output: var MarkerBuffer): MarkerDecodeStatus =
  if not reader.alignToByte(): return mdsUnexpectedEof
  var lengthBits, inverseBits: int
  if not reader.readBits(16, lengthBits) or
     not reader.readBits(16, inverseBits):
    return mdsUnexpectedEof
  let length = uint16(lengthBits)
  if length != not uint16(inverseBits):
    return mdsInvalidStoredLength
  if int(length) > output.maximum - output.count or
     not output.ensureCapacity(output.count + int(length)):
    return mdsOutputLimit
  for _ in 0 ..< int(length):
    var value: int
    if not reader.readBits(8, value): return mdsUnexpectedEof
    discard output.appendLiteral(byte(value))
  mdsBoundary

proc decodeCompressed(reader: var BitReader; literal, distance: HuffmanTable;
                      output: var MarkerBuffer): MarkerDecodeStatus =
  while true:
    var symbol: uint16
    if not literal.tryDecode(reader, symbol):
      return mdsUnexpectedEof
    case symbol
    of 0'u16 .. 255'u16:
      if not output.appendLiteral(byte(symbol)):
        return mdsOutputLimit
    of EndOfBlockSymbol.uint16:
      return mdsBoundary
    of 257'u16 .. 285'u16:
      let lengthIndex = int(symbol) - 257
      var extra: int
      if not reader.readBits(int(LengthExtraBits[lengthIndex]), extra):
        return mdsUnexpectedEof
      let matchLength = int(LengthBases[lengthIndex]) + extra
      var distanceSymbol: uint16
      if not distance.tryDecode(reader, distanceSymbol):
        return if distance.maximumLength == 0: mdsInvalidDistance
               else: mdsUnexpectedEof
      if distanceSymbol > 29:
        return mdsInvalidDistance
      let distanceIndex = int(distanceSymbol)
      if not reader.readBits(int(DistanceExtraBits[distanceIndex]), extra):
        return mdsUnexpectedEof
      let matchDistance = int(DistanceBases[distanceIndex]) + extra
      if matchLength > output.maximum - output.count:
        return mdsOutputLimit
      if not output.copyMatch(matchDistance, matchLength):
        return mdsInvalidDistance
    else:
      return mdsInvalidSymbol

proc decodeMarkerChunk*(source: ReadAtSource; startBit, estimatedStopBit: uint64;
                        maximumSymbols: int;
                        workspace: MarkerDecoderWorkspace;
                        tracker: ptr AllocationTracker = nil;
                        pageSize = BitReaderPageCapacity): MarkerDecodeResult =
  ## Decode complete blocks until BFINAL, the first boundary at/after the
  ## estimated stop, or a boundary with a marker-free active window.
  result.startBit = startBit
  result.output = initMarkerBuffer(maximumSymbols, tracker)
  if workspace.isNil:
    result.status = mdsInvalidDynamicHeader
    return
  var reader = initBitReader(source, startBit, pageSize)
  if not reader.isValid:
    result.status = mdsUnexpectedEof
    return

  while true:
    var header: DeflateBlockHeader
    if not reader.tryReadBlockHeader(header):
      result.status = mdsUnexpectedEof
      return
    case header.blockType
    of dbtStored:
      result.status = reader.decodeStored(result.output)
    of dbtFixed:
      result.status = reader.decodeCompressed(workspace.fixedLiteral,
                                               workspace.fixedDistance,
                                               result.output)
    of dbtDynamic:
      var info: DynamicHeaderInfo
      if reader.parseDynamicHeader(workspace.dynamic, info) != dhsOk:
        result.status = mdsInvalidDynamicHeader
      else:
        result.status = reader.decodeCompressed(workspace.dynamic.literal,
                                                workspace.dynamic.distance,
                                                result.output)
    of dbtReserved:
      result.status = mdsInvalidBlockType
    if result.status != mdsBoundary:
      result.endBit = reader.position
      return

    result.endBit = reader.position
    if header.final:
      if not reader.alignToByte():
        result.status = mdsUnexpectedEof
      else:
        result.endBit = reader.position
        result.status = mdsStreamEnd
      return
    if result.endBit >= estimatedStopBit:
      result.status = mdsBoundary
      return
    if result.output.markerFreeWindow(result.finalWindow):
      result.hasFinalWindow = true
      result.status = mdsMarkerFreeBoundary
      return

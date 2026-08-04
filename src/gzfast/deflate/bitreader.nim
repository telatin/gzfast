## Allocation-free LSB-first bit reader over a positional source.
##
## Peeking may refill the reservoir but never advances the logical bit
## position. Expected EOF is reported as false, which keeps speculative
## block-candidate rejection cheap and exception-free.

import ../source

const
  BitReaderPageCapacity* = 4096
  MaxBitReadWidth* = 32

type
  BitReader* = object
    source: ReadAtSource
    page: array[BitReaderPageCapacity, byte]
    pageStart: uint64
    pageLength: int
    pageSize: int
    nextByteOffset: uint64
    reservoir: uint64
    reservoirBits: int
    bitPosition: uint64
    valid: bool

proc sourceBitLength(source: ReadAtSource): uint64 =
  if source.size > high(uint64) div 8:
    high(uint64)
  else:
    source.size * 8

proc refillPage(reader: var BitReader; offset: uint64): bool =
  if offset >= reader.source.size:
    return false
  reader.pageStart = offset - (offset mod uint64(reader.pageSize))
  let remaining = reader.source.size - reader.pageStart
  let request = int(min(uint64(reader.pageSize), remaining))
  reader.pageLength = reader.source.readAtProc(reader.source.context,
    reader.pageStart, addr reader.page[0], request)
  reader.pageLength > 0

proc nextByte(reader: var BitReader; value: var byte): bool =
  if reader.nextByteOffset >= reader.source.size:
    return false
  if reader.pageLength == 0 or reader.nextByteOffset < reader.pageStart or
     reader.nextByteOffset >= reader.pageStart + uint64(reader.pageLength):
    if not reader.refillPage(reader.nextByteOffset):
      return false
  let index = int(reader.nextByteOffset - reader.pageStart)
  value = reader.page[index]
  inc reader.nextByteOffset
  true

proc ensureBits(reader: var BitReader; count: int): bool =
  if not reader.valid or count < 0 or count > MaxBitReadWidth:
    return false
  while reader.reservoirBits < count:
    var value: byte
    if not reader.nextByte(value):
      return false
    reader.reservoir = reader.reservoir or
      (uint64(value) shl reader.reservoirBits)
    reader.reservoirBits += 8
  true

proc initBitReader*(source: ReadAtSource; startBit = 0'u64;
                    pageSize = BitReaderPageCapacity): BitReader =
  ## Initialize at any bit offset from zero through `source.size * 8`.
  result.source = source
  result.pageSize = min(max(pageSize, 1), BitReaderPageCapacity)
  result.bitPosition = startBit
  let byteOffset = startBit shr 3
  let intraByte = int(startBit and 7)
  if byteOffset > source.size or
     (byteOffset == source.size and intraByte != 0):
    return
  result.nextByteOffset = byteOffset
  result.valid = true
  if intraByte != 0:
    if not result.ensureBits(8):
      result.valid = false
      return
    result.reservoir = result.reservoir shr intraByte
    result.reservoirBits -= intraByte

proc isValid*(reader: BitReader): bool =
  reader.valid

proc position*(reader: BitReader): uint64 =
  reader.bitPosition

proc remainingBits*(reader: BitReader): uint64 =
  let total = reader.source.sourceBitLength()
  if reader.bitPosition >= total: 0 else: total - reader.bitPosition

proc tryPeekBits*(reader: var BitReader; count: int;
                  value: var uint32): bool =
  ## Peek up to 32 bits without advancing.
  if not reader.ensureBits(count):
    return false
  if count == 0:
    value = 0
  elif count == 32:
    value = uint32(reader.reservoir and 0xFFFF_FFFF'u64)
  else:
    value = uint32(reader.reservoir and ((1'u64 shl count) - 1))
  true

proc tryPeekBitsPadded*(reader: var BitReader; count: int;
                        value: var uint32; available: var int): bool =
  ## Peek up to `count` bits, zero-padding unavailable high bits. The
  ## caller must verify its selected code length against `available`.
  if not reader.valid or count < 0 or count > MaxBitReadWidth:
    return false
  available = int(min(uint64(count), reader.remainingBits))
  if available == 0:
    value = 0
    return count == 0
  if not reader.ensureBits(available):
    return false
  if available == 32:
    value = uint32(reader.reservoir and 0xFFFF_FFFF'u64)
  else:
    value = uint32(reader.reservoir and ((1'u64 shl available) - 1))
  true

proc tryReadBits*(reader: var BitReader; count: int;
                  value: var uint32): bool =
  ## Read up to 32 bits. Failure leaves the logical position unchanged;
  ## harmless refill state may remain cached.
  if not reader.tryPeekBits(count, value):
    return false
  reader.reservoir = reader.reservoir shr count
  reader.reservoirBits -= count
  reader.bitPosition += uint64(count)
  true

proc tryAdvance*(reader: var BitReader; count: int): bool =
  var ignored: uint32
  reader.tryReadBits(count, ignored)

proc alignToByte*(reader: var BitReader): bool =
  let skip = int((8 - (reader.bitPosition and 7)) and 7)
  reader.tryAdvance(skip)

proc tryReadByte*(reader: var BitReader; value: var byte): bool =
  var bits: uint32
  if not reader.tryReadBits(8, bits):
    return false
  value = byte(bits)
  true

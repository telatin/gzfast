## Common three-bit DEFLATE block header.

import ./bitreader

type
  DeflateBlockType* = enum
    dbtStored
    dbtFixed
    dbtDynamic
    dbtReserved

  DeflateBlockHeader* = object
    startBit*: uint64
    final*: bool
    blockType*: DeflateBlockType
    payloadHeaderBit*: uint64

proc tryReadBlockHeader*(reader: var BitReader;
                         header: var DeflateBlockHeader): bool =
  header.startBit = reader.position
  var bits: uint32
  if not reader.tryReadBits(3, bits):
    return false
  header.final = (bits and 1) != 0
  header.blockType = DeflateBlockType((bits shr 1) and 3)
  header.payloadHeaderBit = reader.position
  true

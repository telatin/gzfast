## Stored-block header and payload boundary validation.

import ./bitreader

type
  StoredBlockStatus* = enum
    sbsOk
    sbsUnexpectedEof
    sbsInvalidLength

  StoredBlockInfo* = object
    length*: uint16
    payloadStartBit*: uint64
    endBit*: uint64

proc parseStoredBlock*(reader: var BitReader; info: var StoredBlockInfo;
                       consumePayload = true): StoredBlockStatus =
  ## Parse beginning immediately after BFINAL/BTYPE. Alignment padding
  ## bits are ignored as required by RFC 1951.
  if not reader.alignToByte():
    return sbsUnexpectedEof
  var lengthBits, inverseBits: uint32
  if not reader.tryReadBits(16, lengthBits) or
     not reader.tryReadBits(16, inverseBits):
    return sbsUnexpectedEof
  let length = uint16(lengthBits)
  let inverse = uint16(inverseBits)
  if length != not inverse:
    return sbsInvalidLength
  info.length = length
  info.payloadStartBit = reader.position
  let payloadBits = uint64(length) * 8
  if reader.remainingBits < payloadBits:
    return sbsUnexpectedEof
  info.endBit = info.payloadStartBit + payloadBits
  if consumePayload:
    var left = int(length)
    while left > 0:
      let step = min(left, MaxBitReadWidth div 8)
      if not reader.tryAdvance(step * 8):
        return sbsUnexpectedEof
      left -= step
  sbsOk

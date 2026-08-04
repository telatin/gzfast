## BGZF structural block-chain validation.

import ../source
import ./members

type
  BgzfLinkStatus* = enum
    blsOk
    blsEof
    blsNotBgzf
    blsInvalid

  BgzfLink* = object
    status*: BgzfLinkStatus
    startOffset*: uint64
    endOffset*: uint64

proc inspectBgzfLink*(source: ReadAtSource; offset: uint64;
                      maxHeaderSize: int): BgzfLink =
  ## Validate one BSIZE link and the header at its declared successor.
  if offset == source.size:
    return BgzfLink(status: blsEof, startOffset: offset, endOffset: offset)
  let current = source.parseHeaderAt(offset, maxHeaderSize)
  if current.status != hasOk or current.info.bgzfBlockSize <= 0:
    return BgzfLink(status: blsNotBgzf, startOffset: offset)
  let blockSize = uint64(current.info.bgzfBlockSize)
  if blockSize < uint64(current.info.headerSize + 8) or
     blockSize > source.size - offset:
    return BgzfLink(status: blsInvalid, startOffset: offset)
  let next = offset + blockSize
  if next > source.size:
    return BgzfLink(status: blsInvalid, startOffset: offset)
  if next < source.size:
    let successor = source.parseHeaderAt(next, maxHeaderSize)
    if successor.status != hasOk or successor.info.bgzfBlockSize <= 0:
      return BgzfLink(status: blsInvalid, startOffset: offset,
                      endOffset: next)
  BgzfLink(status: blsOk, startOffset: offset, endOffset: next)

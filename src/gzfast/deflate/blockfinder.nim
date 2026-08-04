## Bounded finder for structurally valid non-final dynamic block headers.
##
## A returned offset is only a candidate. Complete block decoding and
## predecessor/successor boundary equality remain mandatory before commit.

import ../source
import ./bitreader, ./block_header, ./dynamic_header

type
  DynamicCandidate* = object
    startBit*: uint64
    headerEndBit*: uint64
    literalCount*: int
    distanceCount*: int

proc findNextDynamicCandidate*(source: ReadAtSource; startBit, endBit: uint64;
                               workspace: DynamicHeaderWorkspace;
                               candidate: var DynamicCandidate;
                               pageSize = BitReaderPageCapacity): bool =
  ## Search [startBit, endBit) without allocating candidate storage.
  if workspace.isNil or startBit >= endBit:
    return false
  let sourceEnd = if source.size > high(uint64) div 8: high(uint64)
                  else: source.size * 8
  let stop = min(endBit, sourceEnd)
  var scanner = initBitReader(source, startBit, pageSize)
  if not scanner.isValid:
    return false

  while scanner.position < stop:
    let current = scanner.position
    var headerBits: uint32
    if not scanner.tryPeekBits(3, headerBits):
      return false
    # Stream bits 100: BFINAL=0, BTYPE=10 (dynamic).
    if headerBits == 4:
      var probe = scanner
      var header: DeflateBlockHeader
      if probe.tryReadBlockHeader(header):
        var info: DynamicHeaderInfo
        if probe.parseDynamicHeader(workspace, info) == dhsOk:
          candidate = DynamicCandidate(
            startBit: current,
            headerEndBit: info.headerEndBit,
            literalCount: info.literalCount,
            distanceCount: info.distanceCount
          )
          return true
    if not scanner.tryAdvance(1):
      return false
  false

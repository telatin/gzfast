## Exact raw-zlib continuation from a known DEFLATE block boundary.

import ../buffers, ../source
import ../private/zlib_api

type
  ExactDecodeStatus* = enum
    edsBoundary
    edsStreamEnd
    edsUnexpectedEof
    edsInvalidDeflate
    edsOutputLimit
    edsBoundaryMismatch
    edsBackendError

  ExactDecodeResult* = object
    status*: ExactDecodeStatus
    startBit*: uint64
    endBit*: uint64
    output*: SharedBuffer

proc release*(result: var ExactDecodeResult; expected = boWorker) =
  result.output.release(expected)
  result.output = SharedBuffer()

proc inflateExactFromBoundary*(source: ReadAtSource; startBit: uint64;
                               dictionary: openArray[byte];
                               maximumOutput: int;
                               minimumStopBit = high(uint64);
                               exactStop = false;
                               tracker: ptr AllocationTracker = nil;
                               pageSize = 4096): ExactDecodeResult =
  result.startBit = startBit
  if maximumOutput < 0 or dictionary.len > 32768:
    result.status = edsBackendError
    return
  if maximumOutput == 0:
    # zlib requires a positive physical avail_out even when the remainder
    # can finish without output. Probe with one byte, then enforce the
    # caller's zero-byte logical allowance on the returned result.
    result = inflateExactFromBoundary(source, startBit, dictionary, 1,
      minimumStopBit, exactStop, tracker, pageSize)
    if result.output.length != 0:
      result.status = edsOutputLimit
    return
  let initial = min(maximumOutput, 64 * 1024)
  result.output = allocSharedBuffer(initial, owner = boWorker,
                                    tracker = tracker)
  let inflater = gzInflaterCreate()
  if inflater.isNil:
    result.status = edsBackendError
    return
  defer: gzInflaterDestroy(inflater)

  var inputOffset = startBit shr 3
  let skippedBits = int(startBit and 7)
  if inputOffset > source.size:
    result.status = edsUnexpectedEof
    return
  if skippedBits != 0:
    var containingByte: byte
    if source.readAtProc(source.context, inputOffset,
                         addr containingByte, 1) != 1:
      result.status = edsUnexpectedEof
      return
    let primeCount = 8 - skippedBits
    let primeValue = cuint(containingByte shr skippedBits)
    if gzInflaterPrime(inflater, cuint(primeCount), primeValue) != gzOk:
      result.status = edsBackendError
      return
    inc inputOffset
  if dictionary.len > 0 and
     gzInflaterSetDictionary(inflater,
       cast[ptr byte](unsafeAddr dictionary[0]), csize_t(dictionary.len)) != gzOk:
    result.status = edsBackendError
    return

  var page: array[4096, byte]
  let actualPageSize = min(max(pageSize, 1), page.len)
  var pageBase = inputOffset
  var pagePos, pageLength: int
  while true:
    if pagePos == pageLength:
      if inputOffset >= source.size:
        result.status = edsUnexpectedEof
        return
      pageBase = inputOffset
      let request = int(min(uint64(actualPageSize), source.size - inputOffset))
      pageLength = source.readAtProc(source.context, inputOffset,
                                     addr page[0], request)
      pagePos = 0
      if pageLength <= 0:
        result.status = edsUnexpectedEof
        return
      inputOffset += uint64(pageLength)

    if result.output.length == result.output.capacity and
       result.output.capacity < maximumOutput:
      result.output.reserve(result.output.length + 1, maximumOutput)

    var inputPtr = addr page[pagePos]
    var inputLength = csize_t(pageLength - pagePos)
    let inputBefore = inputLength
    var dummy: array[1, byte]
    let physicalFull = result.output.length == result.output.capacity
    var outputPtr = if not physicalFull:
                      result.output.byteAt(result.output.length)
                    else:
                      addr dummy[0]
    # One physical discard byte lets zlib parse an output-free final EOB
    # when the logical allowance is exhausted.
    let physicalSpace = result.output.capacity - result.output.length
    var outputLength = csize_t(if physicalSpace > 0: physicalSpace else: 1)
    let outputBefore = outputLength
    let status = gzInflaterStep(inflater, addr inputPtr, addr inputLength,
                                addr outputPtr, addr outputLength, gzBlock)
    let consumed = int(inputBefore - inputLength)
    let produced = int(outputBefore - outputLength)
    pagePos += consumed
    let logicalRemaining = maximumOutput - min(result.output.length,
                                                maximumOutput)
    if produced > logicalRemaining:
      result.endBit = pageBase * 8 + uint64(pagePos * 8)
      result.status = edsOutputLimit
      return
    if produced > 0:
      result.output.setLength(result.output.length + produced)

    let dataType = int(gzInflaterDataType(inflater))
    let unusedBits = dataType and 0x3F
    let consumedByteOffset = pageBase + uint64(pagePos)
    if consumedByteOffset * 8 < uint64(unusedBits):
      result.status = edsBackendError
      return
    var exactPosition = consumedByteOffset * 8 - uint64(unusedBits)
    let atBoundary = (dataType and 0x80) != 0
    let finalBoundary = (dataType and 0x40) != 0

    if status == gzStreamEnd or (atBoundary and finalBoundary):
      exactPosition = (exactPosition + 7) and not 7'u64
      result.endBit = exactPosition
      result.status = edsStreamEnd
      return
    if status == gzDataError:
      result.endBit = exactPosition
      result.status = edsInvalidDeflate
      return
    if status != gzOk and status != gzBufError:
      result.endBit = exactPosition
      result.status = edsBackendError
      return
    if atBoundary and exactPosition >= minimumStopBit:
      result.endBit = exactPosition
      result.status =
        if exactStop and exactPosition != minimumStopBit: edsBoundaryMismatch
        else: edsBoundary
      return
    if result.output.length >= maximumOutput and produced == 0:
      result.endBit = exactPosition
      result.status = edsOutputLimit
      return
    if consumed == 0 and produced == 0:
      if pagePos == pageLength:
        continue
      result.endBit = exactPosition
      result.status = edsInvalidDeflate
      return

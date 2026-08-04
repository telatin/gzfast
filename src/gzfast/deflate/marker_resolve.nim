## Scalar marker replacement and rolling resolved-window derivation.

import ../buffers
import ./marker_decode

type
  MarkerResolveStatus* = enum
    mrsOk
    mrsInvalidSymbol
    mrsWindowTooSmall
    mrsAllocationFailure

  ResolvedWindow* = object
    bytes*: array[DeflateWindowSize, byte]
    length*: int

proc initResolvedWindow*(data: openArray[byte]): ResolvedWindow =
  result.length = min(data.len, DeflateWindowSize)
  let sourceStart = data.len - result.length
  let destinationStart = DeflateWindowSize - result.length
  if result.length > 0:
    copyMem(addr result.bytes[destinationStart], unsafeAddr data[sourceStart],
            result.length)

template asOpenArray*(window: var ResolvedWindow): untyped =
  window.bytes.toOpenArray(DeflateWindowSize - window.length,
                           DeflateWindowSize - 1)

proc resolveSymbol(symbol: uint16; predecessor: ResolvedWindow;
                   value: var byte): MarkerResolveStatus =
  if symbol <= 255:
    value = byte(symbol)
    return mrsOk
  if symbol < MarkerBase:
    return mrsInvalidSymbol
  let index = int(symbol - MarkerBase)
  if index >= DeflateWindowSize:
    return mrsInvalidSymbol
  let missing = DeflateWindowSize - predecessor.length
  if index < missing:
    return mrsWindowTooSmall
  value = predecessor.bytes[index]
  mrsOk

proc resolveMarkers*(marked: MarkerBuffer; predecessor: ResolvedWindow;
                     output: var SharedBuffer;
                     tracker: ptr AllocationTracker = nil): MarkerResolveStatus =
  ## Resolve the complete marked output into an owned byte buffer.
  try:
    output = allocSharedBuffer(marked.count, owner = boCoordinator,
                               tracker = tracker)
  except CatchableError:
    return mrsAllocationFailure
  if marked.count == 0:
    return mrsOk
  let source = cast[ptr UncheckedArray[uint16]](marked.storage.data)
  let destination = cast[ptr UncheckedArray[byte]](output.data)
  let missing = DeflateWindowSize - predecessor.length
  if marked.count >= 128 * 1024 and predecessor.length == DeflateWindowSize:
    var lookup = allocSharedBuffer(65536, owner = boCoordinator,
                                   tracker = tracker)
    let table = cast[ptr UncheckedArray[byte]](lookup.data)
    for i in 0 .. 255: table[i] = byte(i)
    copyMem(addr table[int(MarkerBase)], unsafeAddr predecessor.bytes[0],
            DeflateWindowSize)
    for i in 0 ..< marked.count:
      let symbol = source[i]
      if symbol > 255 and symbol < MarkerBase:
        lookup.release(boCoordinator)
        output.release(boCoordinator)
        return mrsInvalidSymbol
      destination[i] = table[int(symbol)]
    lookup.release(boCoordinator)
  else:
    for i in 0 ..< marked.count:
      let symbol = source[i]
      if symbol <= 255:
        destination[i] = byte(symbol)
      elif symbol < MarkerBase:
        output.release(boCoordinator)
        return mrsInvalidSymbol
      else:
        let index = int(symbol - MarkerBase)
        if index < missing:
          output.release(boCoordinator)
          return mrsWindowTooSmall
        destination[i] = predecessor.bytes[index]
  output.setLength(marked.count)
  mrsOk

proc windowAfter*(predecessor: ResolvedWindow; marked: MarkerBuffer;
                  outWindow: var ResolvedWindow): MarkerResolveStatus =
  ## Resolve only the final at-most-32-KiB dependency suffix.
  let suffixLength = min(marked.count, DeflateWindowSize)
  let retained = min(predecessor.length, DeflateWindowSize - suffixLength)
  outWindow = ResolvedWindow(length: retained + suffixLength)
  let destinationStart = DeflateWindowSize - outWindow.length
  let predecessorStart = DeflateWindowSize - retained
  if retained > 0:
    copyMem(addr outWindow.bytes[destinationStart],
            unsafeAddr predecessor.bytes[predecessorStart], retained)
  let markedStart = marked.count - suffixLength
  for i in 0 ..< suffixLength:
    var value: byte
    let status = resolveSymbol(marked.symbolAt(markedStart + i),
                               predecessor, value)
    if status != mrsOk:
      return status
    outWindow.bytes[destinationStart + retained + i] = value
  mrsOk

proc advanceWindow*(predecessor: ResolvedWindow; decoded: openArray[byte]):
                    ResolvedWindow =
  result.length = min(DeflateWindowSize, predecessor.length + decoded.len)
  let takeDecoded = min(decoded.len, DeflateWindowSize)
  let retainOld = result.length - takeDecoded
  let destinationStart = DeflateWindowSize - result.length
  let predecessorStart = DeflateWindowSize - retainOld
  if retainOld > 0:
    copyMem(addr result.bytes[destinationStart],
            unsafeAddr predecessor.bytes[predecessorStart], retainOld)
  let decodedStart = decoded.len - takeDecoded
  if takeDecoded > 0:
    copyMem(addr result.bytes[destinationStart + retainOld],
            unsafeAddr decoded[decodedStart], takeDecoded)

## Scalar full and suffix-only marker resolution tests.

import std/unittest
import gzfast/buffers
import gzfast/deflate/[marker_decode, marker_resolve]

proc resolvedBytes(buffer: SharedBuffer): seq[byte] =
  result.setLen(buffer.length)
  if buffer.length > 0:
    copyMem(addr result[0], buffer.data, buffer.length)

suite "marker resolution":
  test "mixed literals and first/last markers":
    var predecessorData = newSeq[byte](DeflateWindowSize)
    for i in 0 ..< predecessorData.len:
      predecessorData[i] = byte(i and 0xFF)
    let predecessor = initResolvedWindow(predecessorData)
    var marked = initMarkerBuffer(5)
    defer: marked.release()
    check marked.appendLiteral('A'.byte)
    check marked.copyMatch(DeflateWindowSize, 1) # marker zero
    check marked.appendLiteral('B'.byte)
    # A fresh buffer for newest predecessor marker.
    var newest = initMarkerBuffer(1)
    defer: newest.release()
    check newest.copyMatch(1, 1)

    var output: SharedBuffer
    check resolveMarkers(marked, predecessor, output) == mrsOk
    defer: output.release(boCoordinator)
    check resolvedBytes(output) == @['A'.byte, predecessorData[1], 'B'.byte]
    var newestOutput: SharedBuffer
    check resolveMarkers(newest, predecessor, newestOutput) == mrsOk
    defer: newestOutput.release(boCoordinator)
    check resolvedBytes(newestOutput) == @[predecessorData[^1]]

  test "partial predecessor aligns to newest virtual positions":
    let predecessor = initResolvedWindow([10'u8, 20, 30])
    var newest = initMarkerBuffer(1)
    defer: newest.release()
    check newest.copyMatch(1, 1)
    var output: SharedBuffer
    check resolveMarkers(newest, predecessor, output) == mrsOk
    defer: output.release(boCoordinator)
    check resolvedBytes(output) == @[30'u8]

    var tooOld = initMarkerBuffer(1)
    defer: tooOld.release()
    check tooOld.copyMatch(DeflateWindowSize, 1)
    var rejected: SharedBuffer
    check resolveMarkers(tooOld, predecessor, rejected) == mrsWindowTooSmall
    check rejected.data.isNil

  test "suffix-only window equals full resolution then advancement":
    var predecessorData = newSeq[byte](DeflateWindowSize)
    for i in 0 ..< predecessorData.len:
      predecessorData[i] = byte((i * 13) and 0xFF)
    let predecessor = initResolvedWindow(predecessorData)
    for prefix in [0, 7, DeflateWindowSize - 1, DeflateWindowSize + 31]:
      var marked = initMarkerBuffer(prefix + 512)
      for i in 0 ..< prefix:
        check marked.appendLiteral(byte(i and 0xFF))
      check marked.copyMatch(257, 512)
      var full: SharedBuffer
      check resolveMarkers(marked, predecessor, full) == mrsOk
      var suffixWindow: ResolvedWindow
      check windowAfter(predecessor, marked, suffixWindow) == mrsOk
      let fullBytes = resolvedBytes(full)
      let expected = advanceWindow(predecessor, fullBytes)
      check suffixWindow.length == expected.length
      check suffixWindow.bytes == expected.bytes
      full.release(boCoordinator)
      marked.release()

  test "allocation tracking returns to zero":
    var tracker: AllocationTracker
    tracker.initAllocationTracker()
    let predecessor = initResolvedWindow([1'u8, 2, 3])
    var marked = initMarkerBuffer(10, addr tracker)
    for value in 0'u8 .. 9'u8: check marked.appendLiteral(value)
    var output: SharedBuffer
    check resolveMarkers(marked, predecessor, output, addr tracker) == mrsOk
    output.release(boCoordinator)
    marked.release()
    check tracker.snapshot().currentBytes == 0
    check tracker.snapshot().liveBuffers == 0

  test "large complete-window LUT matches expected symbols":
    var predecessorData = newSeq[byte](DeflateWindowSize)
    for i in 0 ..< predecessorData.len:
      predecessorData[i] = byte((i * 17 + 5) and 0xFF)
    let predecessor = initResolvedWindow(predecessorData)
    var marked = initMarkerBuffer(128 * 1024 + 64)
    check marked.copyMatch(1, 64) # newest predecessor marker repeated
    while marked.count < 128 * 1024 + 64:
      check marked.appendLiteral(byte(marked.count and 0xFF))
    var output: SharedBuffer
    check resolveMarkers(marked, predecessor, output) == mrsOk
    let bytes = cast[ptr UncheckedArray[byte]](output.data)
    for i in 0 ..< 64: check bytes[i] == predecessorData[^1]
    for i in 64 ..< output.length: check bytes[i] == byte(i and 0xFF)
    output.release(boCoordinator)
    marked.release()

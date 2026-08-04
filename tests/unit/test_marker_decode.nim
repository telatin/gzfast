## Milestone 7 marker history, overlap, cap and exact handoff tests.

import std/unittest
import gzfast/source
import gzfast/deflate/[exact_decode, marker_decode]
import gzfast/private/zlib_api
import ../helpers/[deflate_bits, fixtures]

proc buildUnknownMatch(lengthSymbol = 257): seq[byte] =
  var writer: TestBitWriter
  writer.addFixedBlockHeader(final = true)
  writer.addFixedSymbol(lengthSymbol)
  writer.addFixedDistance(0)
  writer.addFixedSymbol(256)
  writer.bytes()

proc fullRawInflate(raw: seq[byte]): string =
  let inflater = gzInflaterCreate()
  defer: gzInflaterDestroy(inflater)
  result = newString(128 * 1024)
  var inputPtr = cast[ptr byte](unsafeAddr raw[0])
  var inputLength = csize_t(raw.len)
  var outputPtr = cast[ptr byte](addr result[0])
  var outputLength = csize_t(result.len)
  let status = gzInflaterStep(inflater, addr inputPtr, addr inputLength,
    addr outputPtr, addr outputLength, gzFinish)
  check status == gzStreamEnd
  result.setLen(result.len - int(outputLength))

suite "marker virtual history":
  test "matches agree with a naive known-window oracle":
    var predecessor = newSeq[byte](DeflateWindowSize)
    for i in 0 ..< predecessor.len:
      predecessor[i] = byte((i * 29 + 7) and 0xFF)
    for prefixLength in [0, 1, 7, 32767, 32768, 33000]:
      for distance in [1, 2, 7, 31, 257, 4096, 32768]:
        for length in [3, 10, 258]:
          var marked = initMarkerBuffer(prefixLength + length)
          var scalar = initMarkerBuffer(prefixLength + length)
          var oracle = predecessor
          for i in 0 ..< prefixLength:
            let value = byte((i * 11 + 3) and 0xFF)
            check marked.appendLiteral(value)
            check scalar.appendLiteral(value)
            oracle.add(value)
          check marked.copyMatch(distance, length)
          check scalar.copyMatchScalar(distance, length)
          check marked.markerCount == scalar.markerCount
          check marked.count == scalar.count
          for _ in 0 ..< length:
            oracle.add(oracle[oracle.len - distance])
          for i in 0 ..< marked.count:
            check marked.symbolAt(i) == scalar.symbolAt(i)
            let symbol = marked.symbolAt(i)
            let resolved =
              if symbol.isLiteral: byte(symbol)
              else: predecessor[symbol.markerIndex]
            check resolved == oracle[DeflateWindowSize + i]
          marked.release()
          scalar.release()

  test "distance-one overlap propagates newest marker":
    let raw = buildUnknownMatch()
    let owner = openMemoryReadAtSource(raw)
    defer: owner.close()
    let workspace = newMarkerDecoderWorkspace()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64), 16,
                                    workspace)
    defer: decoded.output.release()
    check decoded.status == mdsStreamEnd
    check decoded.output.count == 3
    for i in 0 ..< 3:
      check decoded.output.symbolAt(i) == MarkerBase + 32767
    check decoded.output.markerCount == 3

  test "scalar overlap copies newly appended literals":
    var buffer = initMarkerBuffer(300)
    defer: buffer.release()
    # Seed one literal, then perform a distance-one run.
    let raw = block:
      var writer: TestBitWriter
      writer.addFixedBlockHeader(final = true)
      writer.addFixedSymbol(ord('A'))
      writer.addFixedSymbol(285) # length 258
      writer.addFixedDistance(0)
      writer.addFixedSymbol(256)
      writer.bytes()
    let owner = openMemoryReadAtSource(raw)
    defer: owner.close()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64), 300,
                                    newMarkerDecoderWorkspace())
    defer: decoded.output.release()
    check decoded.output.count == 259
    check decoded.output.markerCount == 0
    for i in 0 ..< decoded.output.count:
      check decoded.output.symbolAt(i) == uint16(ord('A'))

  test "all-literal stored output":
    var writer: TestBitWriter
    writer.addBits(1, 1); writer.addBits(0, 2); writer.alignByte()
    writer.addBits(5, 16); writer.addBits(not 5'u16, 16)
    for c in "hello": writer.addByte(byte(c))
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64), 5,
                                    newMarkerDecoderWorkspace(), pageSize = 1)
    defer: decoded.output.release()
    check decoded.status == mdsStreamEnd
    check decoded.output.markerCount == 0
    for i, c in "hello":
      check decoded.output.symbolAt(i) == uint16(ord(c))

  test "dynamic block output equals authoritative raw inflate":
    let rawString = readFixture("raw_deflate.bin")
    let expected = readFixture("raw_deflate.expected")
    let raw = toBytes(rawString)
    let owner = openMemoryReadAtSource(raw)
    defer: owner.close()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64),
      expected.len + 1, newMarkerDecoderWorkspace(), pageSize = 7)
    defer: decoded.output.release()
    check decoded.status == mdsStreamEnd
    check decoded.output.count == expected.len
    check decoded.output.markerCount == 0
    for i, c in expected:
      check decoded.output.symbolAt(i) == uint16(ord(c))

  test "whole-match output cap is enforced":
    let raw = buildUnknownMatch(lengthSymbol = 285)
    let owner = openMemoryReadAtSource(raw)
    defer: owner.close()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64), 257,
                                    newMarkerDecoderWorkspace())
    defer: decoded.output.release()
    check decoded.status == mdsOutputLimit
    check decoded.output.count == 0

suite "marker-free exact handoff":
  test "literal window hands off to dictionary-dependent fixed block":
    var writer: TestBitWriter
    writer.addFixedBlockHeader(final = false)
    for _ in 0 ..< DeflateWindowSize:
      writer.addFixedSymbol(ord('A'))
    writer.addFixedSymbol(256)
    let handoffBit = uint64(writer.bitLength)
    writer.addFixedBlockHeader(final = true)
    writer.addFixedSymbol(285) # 258 bytes, first source is dictionary
    writer.addFixedDistance(0)
    writer.addFixedSymbol(256)
    let raw = writer.bytes()
    check (handoffBit and 7) != 0 # exercises inflatePrime

    let owner = openMemoryReadAtSource(raw)
    defer: owner.close()
    var native = decodeMarkerChunk(owner.view, 0, high(uint64),
      DeflateWindowSize + 1024, newMarkerDecoderWorkspace(), pageSize = 31)
    defer: native.output.release()
    check native.status == mdsMarkerFreeBoundary
    check native.endBit == handoffBit
    check native.hasFinalWindow
    for value in native.finalWindow: check value == byte('A')

    var tail = inflateExactFromBoundary(owner.view, native.endBit,
      native.finalWindow, 1024, tracker = nil, pageSize = 17)
    defer: tail.release()
    check tail.status == edsStreamEnd
    check tail.output.length == 258
    let bytes = cast[ptr UncheckedArray[byte]](tail.output.data)
    for i in 0 ..< tail.output.length: check bytes[i] == byte('A')

    let authoritative = fullRawInflate(raw)
    check authoritative.len == DeflateWindowSize + 258
    for c in authoritative: check c == 'A'

  test "markers before the final window do not block handoff":
    var writer: TestBitWriter
    writer.addFixedBlockHeader(final = false)
    writer.addFixedSymbol(257) # three copies of newest unknown marker
    writer.addFixedDistance(0)
    for _ in 0 ..< DeflateWindowSize:
      writer.addFixedSymbol(ord('B'))
    writer.addFixedSymbol(256)
    writer.addFixedBlockHeader(final = true)
    writer.addFixedSymbol(256)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64),
      DeflateWindowSize + 16, newMarkerDecoderWorkspace())
    defer: decoded.output.release()
    check decoded.status == mdsMarkerFreeBoundary
    check decoded.output.markerCount == 3
    check decoded.hasFinalWindow
    for value in decoded.finalWindow: check value == byte('B')

  test "marker in final window blocks handoff":
    let raw = buildUnknownMatch()
    let owner = openMemoryReadAtSource(raw)
    defer: owner.close()
    var decoded = decodeMarkerChunk(owner.view, 0, high(uint64), 16,
                                    newMarkerDecoderWorkspace())
    defer: decoded.output.release()
    check not decoded.hasFinalWindow

suite "exact block continuation":
  test "Z_BLOCK stops exactly after the first stored block":
    var writer: TestBitWriter
    writer.addBits(0, 1); writer.addBits(0, 2); writer.alignByte()
    writer.addBits(5, 16); writer.addBits(not 5'u16, 16)
    for c in "hello": writer.addByte(byte(c))
    let firstEnd = uint64(writer.bitLength)
    writer.addBits(1, 1); writer.addBits(0, 2); writer.alignByte()
    writer.addBits(5, 16); writer.addBits(not 5'u16, 16)
    for c in "world": writer.addByte(byte(c))
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var exact = inflateExactFromBoundary(owner.view, 0, [], 32,
      minimumStopBit = firstEnd, exactStop = true, pageSize = 3)
    defer: exact.release()
    check exact.status == edsBoundary
    check exact.endBit == firstEnd
    check exact.output.length == 5
    let bytes = cast[ptr UncheckedArray[byte]](exact.output.data)
    for i, c in "hello": check bytes[i] == byte(c)

  test "final empty fixed block is recognized under Z_BLOCK":
    var writer: TestBitWriter
    writer.addFixedBlockHeader(final = true)
    writer.addFixedSymbol(256)
    let owner = openMemoryReadAtSource(writer.bytes())
    defer: owner.close()
    var exact = inflateExactFromBoundary(owner.view, 0, [], 0,
      pageSize = 1)
    defer: exact.release()
    check exact.status == edsStreamEnd
    check exact.output.length == 0
    check (exact.endBit and 7) == 0

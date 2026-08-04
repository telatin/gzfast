## Canonical Huffman validation and decode tests.

import std/unittest
import gzfast/source
import gzfast/deflate/[bitreader, constants, huffman]

proc appendCode(bits: var seq[byte]; code: uint32; length: int) =
  for i in 0 ..< length:
    bits.add(byte((code shr i) and 1))

proc packBits(bits: openArray[byte]): seq[byte] =
  result.setLen((bits.len + 7) div 8)
  for i, bit in bits:
    result[i shr 3] = result[i shr 3] or (bit shl (i and 7))

proc canonicalStreamCode(lengths: openArray[uint8]; wanted: int):
    tuple[code: uint32, length: int] =
  var counts: array[MaxCodeBits + 1, uint32]
  for length in lengths:
    if length != 0: inc counts[int(length)]
  var next: array[MaxCodeBits + 1, uint32]
  var code = 0'u32
  for bits in 1 .. MaxCodeBits:
    code = (code + counts[bits - 1]) shl 1
    next[bits] = code
  for symbol, lengthByte in lengths:
    let length = int(lengthByte)
    if length != 0:
      if symbol == wanted:
        return (reverseLowBits(next[length], length), length)
      inc next[length]

suite "DEFLATE Huffman tables":
  test "valid canonical tree decodes every symbol":
    let lengths = [2'u8, 2, 2, 2]
    var table: HuffmanTable
    check table.buildHuffman(lengths) == hbsOk
    var bits: seq[byte]
    for symbol in 0 ..< lengths.len:
      let encoded = canonicalStreamCode(lengths, symbol)
      bits.appendCode(encoded.code, encoded.length)
    let packed = packBits(bits)
    let owner = openMemoryReadAtSource(packed)
    defer: owner.close()
    var reader = initBitReader(owner.view)
    for expected in 0'u16 .. 3'u16:
      var symbol: uint16
      check table.tryDecode(reader, symbol)
      check symbol == expected

  test "fixed trees contain all RFC symbols":
    var literal, distance: HuffmanTable
    check buildFixedTrees(literal, distance)
    check literal.symbolCount == 288
    check distance.symbolCount == 32
    let lengths = fixedLiteralLengths()
    var bits: seq[byte]
    for wanted in [0, 143, 144, 255, 256, 279, 280, 287]:
      let encoded = canonicalStreamCode(lengths, wanted)
      bits.appendCode(encoded.code, encoded.length)
    let owner = openMemoryReadAtSource(packBits(bits))
    defer: owner.close()
    var reader = initBitReader(owner.view)
    for wanted in [0'u16, 143, 144, 255, 256, 279, 280, 287]:
      var decoded: uint16
      check literal.tryDecode(reader, decoded)
      check decoded == wanted

  test "oversubscribed tree rejected":
    var table: HuffmanTable
    check table.buildHuffman([1'u8, 1, 1]) == hbsOversubscribed

  test "incomplete multi-symbol tree rejected":
    var table: HuffmanTable
    check table.buildHuffman([2'u8, 2]) == hbsIncomplete

  test "one-symbol one-bit tree accepted":
    var table: HuffmanTable
    check table.buildHuffman([0'u8, 1, 0]) == hbsOk
    let owner = openMemoryReadAtSource([0'u8])
    defer: owner.close()
    var reader = initBitReader(owner.view)
    var symbol: uint16
    check table.tryDecode(reader, symbol)
    check symbol == 1

  test "one-symbol longer tree rejected":
    var table: HuffmanTable
    check table.buildHuffman([0'u8, 2, 0]) == hbsIncomplete

  test "empty tree policy is explicit":
    var table: HuffmanTable
    check table.buildHuffman([0'u8, 0]) == hbsEmpty
    check table.buildHuffman([0'u8, 0], allowEmpty = true) == hbsOk
    check table.maximumLength == 0

  test "length above 15 rejected":
    var table: HuffmanTable
    check table.buildHuffman([16'u8]) == hbsLengthTooLong

  test "decode rejects truncated codes":
    var table: HuffmanTable
    check table.buildHuffman([2'u8, 2, 2, 2]) == hbsOk
    let owner = openMemoryReadAtSource([0'u8])
    defer: owner.close()
    var reader = initBitReader(owner.view, 7)
    var symbol: uint16
    check not table.tryDecode(reader, symbol)
    check reader.position == 7

  test "table storage is reusable after failures":
    var table: HuffmanTable
    check table.buildHuffman([2'u8, 2, 2, 2]) == hbsOk
    check table.buildHuffman([1'u8, 1, 1]) == hbsOversubscribed
    check table.buildHuffman([1'u8, 1]) == hbsOk
    let owner = openMemoryReadAtSource([0'u8])
    defer: owner.close()
    var reader = initBitReader(owner.view)
    var symbol: uint16
    check table.tryDecode(reader, symbol)
    check symbol == 0

## Deterministic gzip fixture builders that require no compressor runtime.

import std/strutils
import gzfast/deflate/constants
import gzfast/private/zlib_api
import ./deflate_bits

proc appendLe32(output: var string; value: uint32) =
  for shift in [0, 8, 16, 24]:
    output.add(char((value shr shift) and 0xFF))

proc gzipMember*(raw: seq[byte]; crc: uint32; decodedLength: uint64): string =
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  for value in raw: result.add(char(value))
  result.appendLe32(crc)
  result.appendLe32(uint32(decodedLength and 0xFFFF_FFFF'u64))

proc addLength(writer: var TestBitWriter; length: int) =
  for index in 0 ..< LengthBases.len:
    let base = int(LengthBases[index])
    let extraBits = int(LengthExtraBits[index])
    let maximum = if extraBits == 0: base else: base + (1 shl extraBits) - 1
    if length >= base and length <= maximum:
      writer.addFixedSymbol(257 + index)
      if extraBits > 0: writer.addBits(uint32(length - base), extraBits)
      return
  raise newException(ValueError, "invalid DEFLATE match length")

proc repeatedByteCrc*(value: byte; length: uint64): uint32 =
  let chunk = repeat(char(value), 64 * 1024)
  var remaining = length
  while remaining > 0:
    let count = int(min(uint64(chunk.len), remaining))
    result = gzCrc32(result, cast[ptr byte](unsafeAddr chunk[0]), csize_t(count))
    remaining -= uint64(count)

proc buildRepeatedGzip*(decodedLength: uint64; value = 'A'.byte;
                        markerCandidate = true): string =
  ## Highly compressed single-member stream. Optional initial non-final
  ## dynamic block makes the public marker path eligible.
  var writer: TestBitWriter
  if markerCandidate:
    writer.addMinimalDynamicHeader(final = false)
    writer.addBits(0, 1) # EOB for the one-symbol literal tree
  writer.addFixedBlockHeader(final = true)
  var remaining = decodedLength
  if remaining > 0:
    writer.addFixedSymbol(int(value))
    dec remaining
  while remaining >= 3:
    let count = int(min(258'u64, remaining))
    writer.addLength(count)
    writer.addFixedDistance(0)
    remaining -= uint64(count)
  while remaining > 0:
    writer.addFixedSymbol(int(value))
    dec remaining
  writer.addFixedSymbol(256)
  gzipMember(writer.bytes(), repeatedByteCrc(value, decodedLength),
             decodedLength)

proc buildRepeatedBlocksGzip*(blockCount, decodedPerBlock: int;
                              value = 'A'.byte): string =
  ## Every output block is preceded by a non-final dynamic EOB, providing
  ## genuine marker-grid candidates for scaling benchmarks/tests.
  if blockCount <= 0 or decodedPerBlock <= 0:
    raise newException(ValueError, "block counts must be positive")
  var writer: TestBitWriter
  for blockIndex in 0 ..< blockCount:
    writer.addMinimalDynamicHeader(final = false)
    writer.addBits(0, 1)
    writer.addFixedBlockHeader(final = blockIndex == blockCount - 1)
    var remaining = decodedPerBlock
    writer.addFixedSymbol(int(value)); dec remaining
    while remaining >= 3:
      let count = min(258, remaining)
      writer.addLength(count)
      writer.addFixedDistance(0)
      remaining -= count
    while remaining > 0:
      writer.addFixedSymbol(int(value)); dec remaining
    writer.addFixedSymbol(256)
  let total = uint64(blockCount) * uint64(decodedPerBlock)
  gzipMember(writer.bytes(), repeatedByteCrc(value, total), total)

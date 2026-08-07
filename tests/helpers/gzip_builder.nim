## Deterministic gzip fixture builders that require no compressor runtime.

import std/strutils
import gzfast/deflate/constants
import gzfast/private/zlib_api
import ./deflate_bits

const DeflateWindowSizeForFixtures = 32768

proc appendLe32(output: var string; value: uint32) =
  for shift in [0, 8, 16, 24]:
    output.add(char((value shr shift) and 0xFF))

proc gzipMember*(raw: seq[byte]; crc: uint32; decodedLength: uint64): string =
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  for value in raw: result.add(char(value))
  result.appendLe32(crc)
  result.appendLe32(uint32(decodedLength and 0xFFFF_FFFF'u64))

proc gzipMemberRaw(raw: string; crc: uint32; decodedLength: uint64): string =
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  result.add(raw)
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

proc addDistance(writer: var TestBitWriter; distance: int) =
  for index in 0 ..< DistanceBases.len:
    let base = int(DistanceBases[index])
    let extraBits = int(DistanceExtraBits[index])
    let maximum = if extraBits == 0: base else: base + (1 shl extraBits) - 1
    if distance >= base and distance <= maximum:
      writer.addFixedDistance(index)
      if extraBits > 0: writer.addBits(uint32(distance - base), extraBits)
      return
  raise newException(ValueError, "invalid DEFLATE distance")

proc appendLe16(output: var string; value: uint16) =
  output.add(char(value and 0xFF))
  output.add(char((value shr 8) and 0xFF))

proc stringCrc*(plain: string): uint32 =
  if plain.len == 0:
    return gzCrc32(0, nil, 0)
  result = gzCrc32(0, cast[ptr byte](unsafeAddr plain[0]), csize_t(plain.len))

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

proc repeatedRecordCrc(record: string; count: int): uint32 =
  if record.len == 0:
    return gzCrc32(0, nil, 0)
  for _ in 0 ..< count:
    result = gzCrc32(result, cast[ptr byte](unsafeAddr record[0]),
                     csize_t(record.len))

proc buildRepeatedRecordGzip*(record: string; count: int;
                              markerCandidate = false): string =
  ## Single gzip member containing `count` repetitions of one record. The
  ## payload is intentionally FASTQ/text-shape friendly but generic enough
  ## for non-FASTQ gzip benchmark controls.
  if record.len <= 0 or record.len > DeflateWindowSizeForFixtures:
    raise newException(ValueError, "record length must be 1..32768 bytes")
  if count < 0:
    raise newException(ValueError, "count must be nonnegative")
  var writer: TestBitWriter
  if markerCandidate:
    writer.addMinimalDynamicHeader(final = false)
    writer.addBits(0, 1)
  writer.addFixedBlockHeader(final = true)
  if count > 0:
    for c in record:
      writer.addFixedSymbol(ord(c))
    var remaining = record.len * (count - 1)
    while remaining >= 3:
      let take = min(258, remaining)
      writer.addLength(take)
      writer.addDistance(record.len)
      remaining -= take
    for i in 0 ..< remaining:
      writer.addFixedSymbol(ord(record[i mod record.len]))
  writer.addFixedSymbol(256)
  gzipMember(writer.bytes(), repeatedRecordCrc(record, count),
             uint64(record.len) * uint64(count))

proc buildFixedLiteralGzip*(plain: string): string =
  ## Fixed-Huffman stream containing only literals. This is useful for
  ## line-oriented text controls without relying on an external compressor.
  var writer: TestBitWriter
  writer.addFixedBlockHeader(final = true)
  for c in plain:
    writer.addFixedSymbol(ord(c))
  writer.addFixedSymbol(256)
  gzipMember(writer.bytes(), stringCrc(plain), uint64(plain.len))

proc buildStoredGzip*(plain: string): string =
  ## Stored-block gzip stream for low-compression, I/O-heavy controls.
  var raw = newStringOfCap(plain.len + ((plain.len div 65535) + 1) * 5)
  var offset = 0
  while offset < plain.len or (plain.len == 0 and offset == 0):
    let remaining = plain.len - offset
    let count = min(65535, max(0, remaining))
    let final = offset + count >= plain.len
    raw.add(char(if final: 1 else: 0))
    raw.appendLe16(uint16(count))
    raw.appendLe16(uint16(0xFFFF) xor uint16(count))
    if count > 0:
      raw.add(plain.substr(offset, offset + count - 1))
    offset += count
    if plain.len == 0:
      break
  gzipMemberRaw(raw, stringCrc(plain), uint64(plain.len))

proc bgzfMember*(raw: seq[byte]; crc: uint32; decodedLength: uint64): string =
  const headerSize = 18
  let blockSize = headerSize + raw.len + 8
  if blockSize > 65536:
    raise newException(ValueError, "BGZF block exceeds 64 KiB")
  result = "\x1f\x8b\x08\x04\x00\x00\x00\x00\x00\xff"
  result.appendLe16(6'u16)
  result.add("BC")
  result.appendLe16(2'u16)
  result.appendLe16(uint16(blockSize - 1))
  for value in raw:
    result.add(char(value))
  result.appendLe32(crc)
  result.appendLe32(uint32(decodedLength and 0xFFFF_FFFF'u64))

proc buildRepeatedRecordBgzf*(record: string; recordsPerBlock, blockCount: int):
                              string =
  ## BGZF-like gzip stream with independently framed blocks. Each block
  ## expands to repeated FASTQ/text-shaped records and verifies normally.
  if recordsPerBlock <= 0 or blockCount < 0:
    raise newException(ValueError, "invalid BGZF record/block count")
  let decodedLength = uint64(record.len) * uint64(recordsPerBlock)
  for _ in 0 ..< blockCount:
    var writer: TestBitWriter
    writer.addFixedBlockHeader(final = true)
    for c in record:
      writer.addFixedSymbol(ord(c))
    var remaining = record.len * (recordsPerBlock - 1)
    while remaining >= 3:
      let take = min(258, remaining)
      writer.addLength(take)
      writer.addDistance(record.len)
      remaining -= take
    for i in 0 ..< remaining:
      writer.addFixedSymbol(ord(record[i mod record.len]))
    writer.addFixedSymbol(256)
    result.add(bgzfMember(writer.bytes(), repeatedRecordCrc(record,
      recordsPerBlock), decodedLength))

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

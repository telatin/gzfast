## Generated large logical stream with bounded-memory streaming checks.

import std/[os, unittest]
import gzfast
import gzfast/private/zlib_api
import ../helpers/gzip_builder

proc decodeLarge(path: string; expectedLength: uint64):
    tuple[crc: uint32, report: DecodeReport] =
  var config = defaultGzFastConfig()
  config.threads = 4
  config.enableMarkerPath = true
  config.compressedGridSize = 1024
  config.inputPageSize = 4096
  config.decodedChunkSize = 1024 * 1024
  config.maxSpeculativeOutput = 4 * 1024 * 1024
  config.inFlightChunks = 3
  config.memoryLimit = 96 * 1024 * 1024
  let input = initGzFastDecoder(config).open(path)
  defer: input.close()
  var buffer = newString(4097)
  var total = 0'u64
  while true:
    let count = input.readData(addr buffer[0], buffer.len)
    if count == 0: break
    result.crc = gzCrc32(result.crc, cast[ptr byte](addr buffer[0]),
                         csize_t(count))
    total += uint64(count)
  result.report = input.finish()
  check total == expectedLength

suite "large streaming decode":
  test "doubling logical output does not double internal peak memory":
    var peaks: array[2, uint64]
    for index, sizeMiB in [16, 32]:
      let decodedLength = uint64(sizeMiB) * 1024 * 1024
      let path = getTempDir() / ("gzfast_large_" & $sizeMiB & "m.gz")
      writeFile(path, buildRepeatedGzip(decodedLength, markerCandidate = true))
      defer: removeFile(path)
      let decoded = decodeLarge(path, decodedLength)
      check decoded.crc == repeatedByteCrc('A'.byte, decodedLength)
      check decoded.report.crcVerified
      check decoded.report.memberCount == 1
      check decoded.report.peakBufferedBytes < 96'u64 * 1024 * 1024
      peaks[index] = decoded.report.peakBufferedBytes
    check peaks[1] <= peaks[0] + 16'u64 * 1024 * 1024

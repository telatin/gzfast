## Release benchmark driver. Output is CSV and every run verifies CRC/footer.

import std/[monotimes, os, strformat, strutils, times]
import gzfast
import gzfast/private/zlib_api

proc pathName(paths: set[DecodePath]): string =
  for path in paths:
    if result.len > 0: result.add('+')
    result.add($path)

proc bench(path: string; threads: int) =
  var config = defaultGzFastConfig()
  config.threads = threads
  if "marker-" in path:
    config.enableMarkerPath = true
    config.compressedGridSize = 1024
    config.decodedChunkSize = 1024 * 1024
    config.maxSpeculativeOutput = 4 * 1024 * 1024
  let input = initGzFastDecoder(config).open(path)
  var buffer = newString(1024 * 1024)
  var bytes = 0'u64
  var crc = 0'u32
  let cpuStart = cpuTime()
  let wallStart = getMonoTime()
  while true:
    let count = input.readData(addr buffer[0], buffer.len)
    if count == 0: break
    crc = gzCrc32(crc, cast[ptr byte](addr buffer[0]), csize_t(count))
    bytes += uint64(count)
  let report = input.finish()
  input.close()
  let wall = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
  let cpu = cpuTime() - cpuStart
  doAssert report.crcVerified
  doAssert report.decompressedBytes == bytes
  let mib = bytes.float / (1024 * 1024).float
  echo &"{path.lastPathPart},{threads},{pathName(report.pathsUsed)},{bytes}," &
       &"{wall:.6f},{cpu:.6f},{mib / wall:.3f},{report.peakWorkers}," &
       &"{report.peakBufferedBytes},{crc}"

when isMainModule:
  if paramCount() == 0:
    quit("usage: bench_decode FILE...", 2)
  echo "dataset,threads,paths,decoded_bytes,wall_s,cpu_s,mib_s,peak_workers,peak_buffered_bytes,crc32"
  for index in 1 .. paramCount():
    for threads in [1, 2, 4, 8, 16]:
      bench(paramStr(index), threads)

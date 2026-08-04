## Standalone bounded whole-decoder fuzz harness. Pass input files.

import std/[os, streams]
import gzfast

const FuzzOutputLimit = 8'u64 * 1024 * 1024

proc fuzz(data: string) =
  var config = defaultGzFastConfig()
  config.outputLimit = some(FuzzOutputLimit)
  config.inputPageSize = 4096
  config.decodedChunkSize = 4096
  config.maxSpeculativeOutput = 4096
  let compressed = newStringStream(data)
  var reader: GzFastStream
  try:
    reader = openGzFastSequential(compressed, config)
    var buffer: array[4096, byte]
    var total = 0'u64
    while true:
      let count = reader.readData(addr buffer[0], buffer.len)
      if count == 0: break
      total += uint64(count)
      doAssert total <= FuzzOutputLimit
    let report = reader.finish()
    doAssert report.crcVerified
  except GzFastError, IOError, OSError, ValueError:
    discard
  finally:
    if not reader.isNil: reader.close()
    compressed.close()

when isMainModule:
  if paramCount() == 0: quit("usage: fuzz_decode INPUT...", 2)
  for index in 1 .. paramCount():
    let path = paramStr(index)
    let size = getFileSize(path)
    if size >= 0 and size <= 1024 * 1024:
      fuzz(readFile(path))

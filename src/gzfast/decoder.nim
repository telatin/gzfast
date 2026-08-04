## GzFastDecoder: configured factory for streams and direct-output
## decoding. Until the parallel paths land (later milestones), all
## decoding uses the authoritative sequential path.

import std/streams
import ./config, ./errors, ./report, ./reader

type
  GzFastDecoder* = ref object
    config: GzFastConfig

proc initGzFastDecoder*(config: GzFastConfig): GzFastDecoder =
  config.validate()
  GzFastDecoder(config: config)

proc initGzFastDecoder*(): GzFastDecoder =
  initGzFastDecoder(defaultGzFastConfig())

proc initGzFastDecoder*(threads: int): GzFastDecoder =
  var config = defaultGzFastConfig()
  config.threads = threads
  initGzFastDecoder(config)

proc open*(decoder: GzFastDecoder; path: string): GzFastStream =
  ## Open `path` for forward-only decompression. Path-based input will
  ## use parallel decoding once the parallel paths are implemented.
  openGzFastStreamFromPath(path, decoder.config)

proc openGzFast*(path: string; threads = 0;
                 memoryLimit: int64 = 0): GzFastStream =
  ## Convenience one-call opener.
  var config = defaultGzFastConfig()
  config.threads = threads
  config.memoryLimit = memoryLimit
  initGzFastDecoder(config).open(path)

proc openGzFastSequential*(
    input: Stream;
    config = defaultGzFastConfig()): GzFastStream =
  ## Decode from a non-positional compressed source (pipe, socket,
  ## memory stream). Always uses the authoritative sequential backend;
  ## the input stream is not closed by gzfast.
  config.validate()
  openGzFastStreamFromStream(input, config)

proc decodeTo*(decoder: GzFastDecoder; inputPath: string;
               output: Stream): DecodeReport =
  ## Decode `inputPath` writing to `output`. Only the caller's thread
  ## touches `output`, so it need not be thread-safe.
  if output.isNil:
    raise newGzFastError(geOutputIo, "nil output stream")
  let reader = decoder.open(inputPath)
  try:
    var buf = newString(decoder.config.decodedChunkSize)
    while true:
      let n = reader.readData(addr buf[0], buf.len)
      if n == 0:
        break
      try:
        output.writeData(addr buf[0], n)
      except IOError as e:
        raise newGzFastError(geOutputIo, "output write failed: " & e.msg,
          memberIndex = 0)
    reader.finish()
  finally:
    reader.close()

proc decodeTo*(decoder: GzFastDecoder; inputPath: string;
               output: File): DecodeReport =
  ## Decode `inputPath` writing to an open `File`.
  if output.isNil:
    raise newGzFastError(geOutputIo, "nil output file")
  let reader = decoder.open(inputPath)
  try:
    var buffer = newString(decoder.config.decodedChunkSize)
    while true:
      let count = reader.readData(addr buffer[0], buffer.len)
      if count == 0: break
      if output.writeBuffer(addr buffer[0], count) != count:
        raise newGzFastError(geOutputIo, "output file write failed")
    reader.finish()
  finally:
    reader.close()

proc decompressFile*(inputPath: string; outputPath: string;
                     config = defaultGzFastConfig()): DecodeReport =
  ## One-call file-to-file decompression.
  let decoder = initGzFastDecoder(config)
  var outFile: File
  if not open(outFile, outputPath, fmWrite):
    raise newGzFastError(geOutputIo, "cannot open output file: " & outputPath)
  try:
    decodeTo(decoder, inputPath, outFile)
  finally:
    outFile.close()

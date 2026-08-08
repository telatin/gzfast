## gzfast command-line utility. Uses only the public library API.

import std/[monotimes, os, parseopt, streams, strutils, terminal, times]
import ./gzfast

const
  version = "0.2.0"

const helpText = """
gzfast — fast, verified gzip I/O (no system zlib required)

Usage:
  gzfast [options] FILE
  gzfast -dc [options] FILE
  gzfast -c [options] [FILE]
  gzfast --verify [options] FILE

Options:
  -d, --decompress       decompress (default)
  -c, --compress         compress; read stdin when FILE is omitted
      --stdout           write to standard output
  -o, --output PATH      write to PATH
  -t, --threads N        maximum worker threads (0 = automatic)
      --memory SIZE      approximate internal memory ceiling (e.g. 256MiB)
      --output-limit SIZE
                         refuse to decode beyond SIZE bytes (bomb guard)
      --marker-path      enable experimental ordinary-gzip marker parallelism
      --verify           verify only; discard decoded output
      --stats            print an operation report to stderr
      --quiet            suppress non-error messages
  -f, --force            allow overwriting existing output and binary on a TTY
      --version          print version
  -h, --help             show this help

Exit codes: 0 ok, 1 corrupt/truncated gzip data, 2 usage error,
3 input/output error, 4 internal error.
"""

type
  CliOptions = object
    inputPath: string
    outputPath: string
    compress: bool
    decompressExplicit: bool
    longCompress: bool
    toStdout: bool
    force: bool
    verifyOnly: bool
    showStats: bool
    quiet: bool
    config: GzFastConfig

proc parseSize(s: string): uint64 =
  ## Parse byte sizes with optional binary suffixes: 512K, 4MiB, 1G.
  var num = s.strip()
  var mult = 1'u64
  let lower = num.toLowerAscii()
  for (suffix, m) in [("kib", 1'u64 shl 10), ("mib", 1'u64 shl 20),
                      ("gib", 1'u64 shl 30), ("tib", 1'u64 shl 40),
                      ("kb", 1'u64 shl 10), ("mb", 1'u64 shl 20),
                      ("gb", 1'u64 shl 30), ("tb", 1'u64 shl 40),
                      ("k", 1'u64 shl 10), ("m", 1'u64 shl 20),
                      ("g", 1'u64 shl 30), ("t", 1'u64 shl 40),
                      ("b", 1'u64)]:
    if lower.endsWith(suffix):
      mult = m
      num = num[0 ..< num.len - suffix.len].strip()
      break
  try:
    result = parseUInt(num) * mult
  except ValueError:
    raise newException(ValueError, "invalid size: " & s)

proc optionValue(p: var OptParser; name: string): string =
  ## Option value accepting both attached (`--opt=val`, `-oval`) and
  ## space-separated (`--opt val`, `-o val`) forms. std/parseopt only
  ## consumes the following argument for long options, so short options
  ## with a separate value are read explicitly here.
  if p.val.len > 0:
    return p.val
  p.next()
  if p.kind != cmdArgument:
    raise newException(ValueError, "option --" & name & " requires a value")
  p.key

proc parseArgs(): CliOptions =
  result.config = defaultGzFastConfig()
  var p = initOptParser(commandLineParams(),
    shortNoVal = {'d', 'c', 'f', 'h'},
    longNoVal = @["d", "decompress", "c", "compress", "stdout", "marker-path",
                  "verify", "stats", "quiet", "f", "force",
                  "version", "h", "help"])
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      if result.inputPath.len != 0:
        raise newException(ValueError,
          "multiple input files given; expected exactly one")
      result.inputPath = p.key
    of cmdShortOption, cmdLongOption:
      case p.key
      of "d", "decompress": result.decompressExplicit = true
      of "c": result.compress = true
      of "compress":
        result.compress = true
        result.longCompress = true
      of "stdout": result.toStdout = true
      of "o", "output": result.outputPath = p.optionValue("output")
      of "t", "threads":
        let value = p.optionValue("threads")
        try:
          result.config.threads = parseInt(value)
        except ValueError:
          raise newException(ValueError, "invalid thread count: " & value)
      of "memory":
        result.config.memoryLimit = parseSize(p.optionValue("memory")).int64
      of "output-limit":
        result.config.outputLimit = some(parseSize(p.optionValue("output-limit")))
      of "marker-path": result.config.enableMarkerPath = true
      of "verify": result.verifyOnly = true
      of "stats": result.showStats = true
      of "quiet": result.quiet = true
      of "f", "force": result.force = true
      of "version":
        stdout.writeLine("gzfast " & version)
        quit(0)
      of "h", "help":
        stdout.writeLine(helpText)
        quit(0)
      else:
        raise newException(ValueError, "unknown option: --" & p.key)
  # Preserve the established `-dc` spelling for decompression to stdout.
  if result.decompressExplicit and result.compress:
    if result.longCompress:
      raise newException(ValueError,
        "--compress and --decompress cannot be used together")
    result.compress = false
    result.toStdout = true
  if result.compress and result.verifyOnly:
    raise newException(ValueError,
      "--verify is only available for decompression")
  if result.compress and result.toStdout and result.outputPath.len > 0:
    raise newException(ValueError,
      "--stdout and --output cannot be used together")
  if result.inputPath.len == 0 and not result.compress:
    raise newException(ValueError, "no input file given")

proc defaultOutputPath(inputPath: string): string =
  if inputPath.endsWith(".gz"):
    inputPath[0 ..< inputPath.len - 3]
  elif inputPath.endsWith(".bgz"):
    inputPath[0 ..< inputPath.len - 4]
  else:
    raise newException(ValueError,
      "input does not end in .gz; use -o or --stdout to choose an output")

proc pathName(paths: set[DecodePath]): string =
  for path in paths:
    if result.len > 0: result.add('+')
    result.add($path)
  if result.len == 0:
    result = "none"

proc formatSeconds(value: float): string =
  value.formatFloat(ffDecimal, 6)

proc throughputMiB(report: DecodeReport; elapsedSeconds: float): float =
  if elapsedSeconds <= 0.0:
    0.0
  else:
    (report.decompressedBytes.float / (1024.0 * 1024.0)) / elapsedSeconds

proc printReport(report: DecodeReport; elapsedSeconds, cpuSeconds: float) =
  stderr.writeLine("gzfast: members=" & $report.memberCount &
    " paths=" & pathName(report.pathsUsed) &
    " compressed=" & $report.compressedBytes & "B" &
    " decompressed=" & $report.decompressedBytes & "B" &
    " crcVerified=" & $report.crcVerified &
    " peakWorkers=" & $report.peakWorkers &
    " peakBuffered=" & $report.peakBufferedBytes & "B" &
    " wall=" & elapsedSeconds.formatSeconds & "s" &
    " cpu=" & cpuSeconds.formatSeconds & "s" &
    " throughput=" & report.throughputMiB(elapsedSeconds).formatSeconds &
    "MiB/s")

proc printWriteReport(report: GzipWriteReport;
                      elapsedSeconds, cpuSeconds: float) =
  let throughput =
    if elapsedSeconds <= 0.0: 0.0
    else: (report.uncompressedBytes.float / (1024.0 * 1024.0)) / elapsedSeconds
  stderr.writeLine("gzfast: compressed=" & $report.compressedBytes & "B" &
    " uncompressed=" & $report.uncompressedBytes & "B" &
    " crc32=" & $report.crc32 &
    " isize=" & $report.isize &
    " wall=" & elapsedSeconds.formatSeconds & "s" &
    " cpu=" & cpuSeconds.formatSeconds & "s" &
    " throughput=" & throughput.formatSeconds & "MiB/s")

proc compressInput(input: File; writer: GzFastWriter): GzipWriteReport =
  var buffer = newSeq[byte](1 shl 20)
  while true:
    let count = input.readBuffer(addr buffer[0], buffer.len)
    if count == 0:
      break
    discard writer.writeData(addr buffer[0], count)
  writer.finish()

proc runCompression(opts: CliOptions): int =
  if opts.inputPath.len > 0 and opts.inputPath != "-" and
      opts.outputPath.len > 0 and fileExists(opts.inputPath) and
      fileExists(opts.outputPath):
    try:
      if sameFile(opts.inputPath, opts.outputPath):
        stderr.writeLine("gzfast: input and output refer to the same file")
        return 2
    except OSError:
      discard
  if opts.outputPath.len > 0 and fileExists(opts.outputPath) and not opts.force:
    stderr.writeLine("gzfast: " & opts.outputPath &
      " already exists (use -f to overwrite)")
    return 2
  if opts.outputPath.len == 0 and isatty(stdout) and not opts.force:
    stderr.writeLine("gzfast: refusing to write compressed-binary " &
      "output to a terminal (use -f to force)")
    return 2

  var input = stdin
  var ownsInput = false
  if opts.inputPath.len > 0 and opts.inputPath != "-":
    if not open(input, opts.inputPath, fmRead):
      raise newException(IOError,
        "cannot open input file: " & opts.inputPath)
    ownsInput = true
  defer:
    if ownsInput:
      input.close()

  let writer =
    if opts.outputPath.len > 0: openGzFastWriter(opts.outputPath)
    else: openGzFastWriter(stdout, ownsOutput = false)
  let wallStart = getMonoTime()
  let cpuStart = cpuTime()
  var report: GzipWriteReport
  try:
    report = compressInput(input, writer)
  finally:
    writer.close()
  let elapsed = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
  let cpu = cpuTime() - cpuStart
  if not opts.quiet and opts.outputPath.len > 0:
    stderr.writeLine("gzfast: wrote " & opts.outputPath)
  if opts.showStats:
    printWriteReport(report, elapsed, cpu)
  0

proc mapError(e: ref GzFastError): int =
  stderr.writeLine("gzfast: error: " & e.msg &
    " (compressed offset " & $e.compressedOffset &
    ", member " & $e.memberIndex & ")")
  case e.kind
  of geInputIo, geOutputIo: 3
  of geInvalidHeader, geInvalidDeflate, geTruncatedInput,
     geChecksumMismatch, geSizeMismatch, geOutputLimit: 1
  of geCancelled, geInternal: 4

proc main(): int =
  var opts: CliOptions
  try:
    opts = parseArgs()
    opts.config.validate()
  except ValueError as e: # includes GzFastConfigError
    stderr.writeLine("gzfast: " & e.msg)
    return 2

  try:
    if opts.compress:
      return runCompression(opts)

    let decoder = initGzFastDecoder(opts.config)
    if opts.verifyOnly:
      let wallStart = getMonoTime()
      let cpuStart = cpuTime()
      let reader = decoder.open(opts.inputPath)
      let report = reader.finish()
      reader.close()
      let elapsed = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
      let cpu = cpuTime() - cpuStart
      if not opts.quiet:
        stderr.writeLine("gzfast: " & opts.inputPath & ": OK")
      if opts.showStats:
        printReport(report, elapsed, cpu)
      return 0

    if opts.toStdout:
      if isatty(stdout) and not opts.force:
        stderr.writeLine("gzfast: refusing to write compressed-binary " &
          "output to a terminal (use -f to force)")
        return 2
      let wallStart = getMonoTime()
      let cpuStart = cpuTime()
      let report = decoder.decodeTo(opts.inputPath, stdout)
      let elapsed = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
      let cpu = cpuTime() - cpuStart
      if opts.showStats:
        printReport(report, elapsed, cpu)
      return 0

    let outPath =
      if opts.outputPath.len > 0: opts.outputPath
      else:
        try:
          defaultOutputPath(opts.inputPath)
        except ValueError as e:
          stderr.writeLine("gzfast: " & e.msg)
          return 2
    if fileExists(outPath) and not opts.force:
      stderr.writeLine("gzfast: " & outPath &
        " already exists (use -f to overwrite)")
      return 2
    let wallStart = getMonoTime()
    let cpuStart = cpuTime()
    let report = decompressFile(opts.inputPath, outPath, opts.config)
    let elapsed = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
    let cpu = cpuTime() - cpuStart
    if not opts.quiet:
      stderr.writeLine("gzfast: wrote " & outPath)
    if opts.showStats:
      printReport(report, elapsed, cpu)
    0
  except GzFastError as e:
    mapError(e)
  except IOError as e:
    stderr.writeLine("gzfast: I/O error: " & e.msg)
    3
  except CatchableError as e:
    stderr.writeLine("gzfast: internal error: " & e.msg)
    4

when isMainModule:
  quit(main())

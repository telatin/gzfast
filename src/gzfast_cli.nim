## gzfast command-line utility. Uses only the public library API.

import std/[os, parseopt, streams, strutils, terminal]
import ./gzfast

const
  version = "0.1.0"

const helpText = """
gzfast — fast, verified gzip decompression (no system zlib required)

Usage:
  gzfast [options] FILE
  gzfast -dc [options] FILE
  gzfast --verify [options] FILE

Options:
  -d, --decompress       decompress (default; compression is not supported)
  -c, --stdout           write to standard output
  -o, --output PATH      write to PATH
  -t, --threads N        maximum worker threads (0 = automatic)
      --memory SIZE      approximate internal memory ceiling (e.g. 256MiB)
      --output-limit SIZE
                         refuse to decode beyond SIZE bytes (bomb guard)
      --verify           verify only; discard decoded output
      --stats            print a decode report to stderr
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

proc parseArgs(): CliOptions =
  result.config = defaultGzFastConfig()
  var p = initOptParser(commandLineParams(),
    shortNoVal = {'d', 'c', 'f', 'h'},
    longNoVal = @["d", "decompress", "c", "stdout", "verify", "stats",
                  "quiet", "f", "force", "version", "h", "help"])
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
      of "d", "decompress": discard
      of "c", "stdout": result.toStdout = true
      of "o", "output": result.outputPath = p.val
      of "t", "threads":
        try:
          result.config.threads = parseInt(p.val)
        except ValueError:
          raise newException(ValueError, "invalid thread count: " & p.val)
      of "memory":
        result.config.memoryLimit = parseSize(p.val).int64
      of "output-limit":
        result.config.outputLimit = some(parseSize(p.val))
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
  if result.inputPath.len == 0:
    raise newException(ValueError, "no input file given")

proc defaultOutputPath(inputPath: string): string =
  if inputPath.endsWith(".gz"):
    inputPath[0 ..< inputPath.len - 3]
  elif inputPath.endsWith(".bgz"):
    inputPath[0 ..< inputPath.len - 4]
  else:
    raise newException(ValueError,
      "input does not end in .gz; use -o or -c to choose an output")

proc printReport(report: DecodeReport) =
  stderr.writeLine("gzfast: members=" & $report.memberCount &
    " compressed=" & $report.compressedBytes & "B" &
    " decompressed=" & $report.decompressedBytes & "B" &
    " crcVerified=" & $report.crcVerified &
    " peakBuffered=" & $report.peakBufferedBytes & "B")

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

  let decoder = initGzFastDecoder(opts.config)

  try:
    if opts.verifyOnly:
      let reader = decoder.open(opts.inputPath)
      let report = reader.finish()
      reader.close()
      if not opts.quiet:
        stderr.writeLine("gzfast: " & opts.inputPath & ": OK")
      if opts.showStats:
        printReport(report)
      return 0

    if opts.toStdout:
      if isatty(stdout) and not opts.force:
        stderr.writeLine("gzfast: refusing to write compressed-binary " &
          "output to a terminal (use -f to force)")
        return 2
      let report = decoder.decodeTo(opts.inputPath, stdout)
      if opts.showStats:
        printReport(report)
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
    let report = decompressFile(opts.inputPath, outPath, opts.config)
    if not opts.quiet:
      stderr.writeLine("gzfast: wrote " & outPath)
    if opts.showStats:
      printReport(report)
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

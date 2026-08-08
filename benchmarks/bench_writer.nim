## Deterministic gzip writer benchmark with external single-thread baselines.

import std/[algorithm, math, monotimes, os, osproc, parsecsv, parseopt,
            strformat, strutils, tables, times]

import gzfast
import gzfast/private/zlib_api

const
  benchLevels = [1, 6, 9]
  defaultDatasets = @["text", "random", "fastq"]

type
  BenchOptions = object
    size: uint64
    repeats: int
    warmups: int
    workDir: string
    keepData: bool
    includeGzip: bool
    includePigz: bool
    requirePigz: bool
    summaryPath: string
    datasets: seq[string]

  Dataset = object
    name: string
    path: string
    bytes: uint64
    crc32: uint32

  RunResult = object
    wall: float
    cpu: float
    compressedBytes: uint64
    exitCode: int

  SummaryGroup = object
    dataset: string
    variant: string
    level: int
    inputBytes: uint64
    successfulRuns: int
    failedRuns: int
    walls: seq[float]
    throughputs: seq[float]
    ratios: seq[float]

proc csv(value: string): string =
  result = "\""
  for c in value:
    if c == '"': result.add("\"\"")
    else: result.add(c)
  result.add('"')

proc optionValue(p: var OptParser; name: string): string =
  if p.val.len > 0:
    return p.val
  p.next()
  if p.kind != cmdArgument:
    raise newException(ValueError, "--" & name & " requires a value")
  p.key

proc parseSize(value: string): uint64 =
  var number = value.strip()
  var multiplier = 1'u64
  let lower = number.toLowerAscii()
  for (suffix, scale) in [("gib", 1'u64 shl 30), ("mib", 1'u64 shl 20),
                          ("kib", 1'u64 shl 10), ("gb", 1'u64 shl 30),
                          ("mb", 1'u64 shl 20), ("kb", 1'u64 shl 10),
                          ("g", 1'u64 shl 30), ("m", 1'u64 shl 20),
                          ("k", 1'u64 shl 10), ("b", 1'u64)]:
    if lower.endsWith(suffix):
      multiplier = scale
      number = number[0 ..< number.len - suffix.len].strip()
      break
  try:
    result = parseBiggestUInt(number).uint64 * multiplier
  except ValueError:
    raise newException(ValueError, "invalid size: " & value)

proc parseDatasets(value: string): seq[string] =
  for part in value.split(','):
    let name = part.strip().toLowerAscii()
    if name.len == 0:
      continue
    if name notin defaultDatasets:
      raise newException(ValueError, "unknown dataset: " & name)
    if name notin result:
      result.add(name)
  if result.len == 0:
    raise newException(ValueError, "no datasets selected")

proc parseArgs(): BenchOptions =
  result.size = 64'u64 shl 20
  result.repeats = 3
  result.warmups = 1
  result.workDir = getTempDir() / "gzfast-writer-bench"
  result.includeGzip = true
  result.includePigz = true
  result.datasets = defaultDatasets
  var parser = initOptParser(commandLineParams(), shortNoVal = {'h'},
    longNoVal = @["help", "keep-data", "no-gzip", "no-pigz",
                  "require-pigz"])
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdArgument:
      raise newException(ValueError, "unexpected argument: " & parser.key)
    of cmdShortOption, cmdLongOption:
      case parser.key
      of "h", "help":
        echo "usage: bench_writer [--size 64MiB] [--repeat 3] [--warmup 1]"
        echo "                    [--datasets text,random,fastq] [--work-dir DIR]"
        echo "                    [--no-gzip] [--no-pigz|--require-pigz] [--keep-data]"
        echo "       bench_writer --summary RESULTS.csv"
        quit(0)
      of "size": result.size = parseSize(parser.optionValue("size"))
      of "repeat": result.repeats = parseInt(parser.optionValue("repeat"))
      of "warmup": result.warmups = parseInt(parser.optionValue("warmup"))
      of "datasets":
        result.datasets = parseDatasets(parser.optionValue("datasets"))
      of "work-dir": result.workDir = parser.optionValue("work-dir")
      of "summary": result.summaryPath = parser.optionValue("summary")
      of "keep-data": result.keepData = true
      of "no-gzip": result.includeGzip = false
      of "no-pigz": result.includePigz = false
      of "require-pigz":
        result.includePigz = true
        result.requirePigz = true
      else:
        raise newException(ValueError, "unknown option: --" & parser.key)
  if result.size == 0:
    raise newException(ValueError, "--size must be positive")
  if result.repeats <= 0:
    raise newException(ValueError, "--repeat must be positive")
  if result.warmups < 0:
    raise newException(ValueError, "--warmup must be >= 0")

proc checkedWrite(output: File; data: pointer; count: int) =
  if count > 0 and output.writeBuffer(data, count) != count:
    raise newException(IOError, "short write while generating benchmark data")

proc appendTwoDigits(output: var string; value: int) =
  if value < 10: output.add('0')
  output.add($value)

proc generateRecordDataset(name, path: string; targetBytes: uint64): Dataset =
  var output: File
  if not open(output, path, fmWrite):
    raise newException(IOError, "cannot create benchmark dataset: " & path)
  defer: output.close()
  var remaining = targetBytes
  var ordinal = 0
  var buffer = newStringOfCap(1 shl 20)
  while remaining > 0:
    buffer.setLen(0)
    while buffer.len < 1 shl 20:
      if name == "text":
        buffer.add("2026-08-08T14:")
        buffer.appendTwoDigits(ordinal mod 60)
        buffer.add(":")
        buffer.appendTwoDigits((ordinal * 7) mod 60)
        buffer.add("Z level=")
        buffer.add(["INFO", "WARN", "DEBUG", "ERROR"][ordinal mod 4])
        buffer.add(" request=")
        buffer.add($(ordinal mod 100003))
        buffer.add(" bytes=")
        buffer.add($((ordinal * 7919) mod 10_000_000))
        buffer.add(" message=deterministic generic writer benchmark line\n")
      else:
        buffer.add("@READ_")
        buffer.add($ordinal)
        buffer.add(" instrument=GZFAST lane=")
        buffer.add($((ordinal mod 4) + 1))
        buffer.add("\n")
        for i in 0 ..< 150:
          buffer.add("ACGT"[(i + ordinal) and 3])
        buffer.add("\n+\n")
        for i in 0 ..< 150:
          buffer.add(chr(ord('!') + ((i * 11 + ordinal) mod 40)))
        buffer.add('\n')
      inc ordinal
      if uint64(buffer.len) >= remaining:
        break
    let count = int(min(remaining, uint64(buffer.len)))
    output.checkedWrite(unsafeAddr buffer[0], count)
    result.crc32 = gzCrc32(result.crc32, cast[ptr byte](unsafeAddr buffer[0]),
                           csize_t(count))
    remaining -= uint64(count)
  result.name = name
  result.path = path
  result.bytes = targetBytes

proc generateRandomDataset(path: string; targetBytes: uint64): Dataset =
  var output: File
  if not open(output, path, fmWrite):
    raise newException(IOError, "cannot create benchmark dataset: " & path)
  defer: output.close()
  var remaining = targetBytes
  var state = 0x1234_5678'u32
  var buffer = newSeq[byte](1 shl 20)
  while remaining > 0:
    let count = int(min(remaining, uint64(buffer.len)))
    for i in 0 ..< count:
      state = state * 1664525'u32 + 1013904223'u32
      buffer[i] = byte(state shr 24)
    output.checkedWrite(addr buffer[0], count)
    result.crc32 = gzCrc32(result.crc32, addr buffer[0], csize_t(count))
    remaining -= uint64(count)
  result = Dataset(name: "random", path: path, bytes: targetBytes,
                   crc32: result.crc32)

proc generateDataset(name, workDir: string; size: uint64): Dataset =
  let path = workDir / ("writer-" & name & ".dat")
  case name
  of "text", "fastq": generateRecordDataset(name, path, size)
  of "random": generateRandomDataset(path, size)
  else: raise newException(ValueError, "unknown dataset: " & name)

proc verifyOutput(path: string; dataset: Dataset) =
  let input = openGzFast(path, threads = 1)
  defer: input.close()
  var buffer = newSeq[byte](1 shl 20)
  var bytes = 0'u64
  var crc = 0'u32
  while true:
    let count = input.readData(addr buffer[0], buffer.len)
    if count == 0: break
    crc = gzCrc32(crc, addr buffer[0], csize_t(count))
    bytes += uint64(count)
  let report = input.finish()
  doAssert report.crcVerified
  doAssert bytes == dataset.bytes
  doAssert crc == dataset.crc32

proc cleanup(path: string) =
  if fileExists(path):
    try: removeFile(path)
    except OSError: discard

proc runGzFast(dataset: Dataset; level: int; outputPath: string): RunResult =
  cleanup(outputPath)
  var config = defaultGzFastWriteConfig()
  config.level = level
  var buffer = newSeq[byte](1 shl 20)
  let cpuStart = cpuTime()
  let wallStart = getMonoTime()
  var input: File
  if not open(input, dataset.path, fmRead):
    raise newException(IOError, "cannot open benchmark input: " & dataset.path)
  let writer = openGzFastWriter(outputPath, config)
  while true:
    let count = input.readBuffer(addr buffer[0], buffer.len)
    if count == 0: break
    discard writer.writeData(addr buffer[0], count)
  let report = writer.finish()
  writer.close()
  input.close()
  result.wall = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
  result.cpu = cpuTime() - cpuStart
  result.exitCode = 0
  result.compressedBytes = uint64(getFileSize(outputPath))
  doAssert report.uncompressedBytes == dataset.bytes
  doAssert report.crc32 == dataset.crc32
  doAssert report.compressedBytes == result.compressedBytes
  verifyOutput(outputPath, dataset)

proc runExternal(tool: string; dataset: Dataset; level: int;
                 outputPath: string): RunResult =
  cleanup(outputPath)
  let command =
    if tool == "pigz":
      "pigz -n -p 1 -" & $level & " -c " & quoteShell(dataset.path) &
        " > " & quoteShell(outputPath)
    else:
      "gzip -n -" & $level & " -c " & quoteShell(dataset.path) &
        " > " & quoteShell(outputPath)
  let wallStart = getMonoTime()
  result.exitCode = execShellCmd(command)
  result.wall = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
  if result.exitCode == 0:
    result.compressedBytes = uint64(getFileSize(outputPath))
    verifyOutput(outputPath, dataset)

proc throughput(inputBytes: uint64; wall: float): float =
  if wall <= 0.0: 0.0
  else: inputBytes.float / (1024.0 * 1024.0) / wall

proc printHeader() =
  echo "dataset,input_bytes,input_crc32,variant,level,iteration,wall_s," &
       "cpu_s,mib_s,compressed_bytes,compression_ratio,exit_code"

proc printRun(dataset: Dataset; variant: string; level, iteration: int;
              run: RunResult) =
  let ratio =
    if dataset.bytes == 0: 0.0
    else: run.compressedBytes.float / dataset.bytes.float
  let cpu = if variant == "gzfast": &"{run.cpu:.6f}" else: ""
  echo &"{csv(dataset.name)},{dataset.bytes},{dataset.crc32},{variant}," &
       &"{level},{iteration},{run.wall:.6f},{cpu}," &
       &"{throughput(dataset.bytes, run.wall):.3f},{run.compressedBytes}," &
       &"{ratio:.6f},{run.exitCode}"

proc outputPath(workDir: string; dataset: Dataset; variant: string;
                level: int): string =
  workDir / (dataset.name & "." & variant & ".level" & $level & ".gz")

proc runVariant(dataset: Dataset; variant: string; level: int;
                workDir: string): RunResult =
  let path = outputPath(workDir, dataset, variant, level)
  case variant
  of "gzfast": result = runGzFast(dataset, level, path)
  of "gzip": result = runExternal("gzip", dataset, level, path)
  of "pigz-p1": result = runExternal("pigz", dataset, level, path)
  else: raise newException(ValueError, "unknown variant: " & variant)
  cleanup(path)

proc mean(values: seq[float]): float =
  for value in values: result += value
  result /= values.len.float

proc stddev(values: seq[float]): float =
  if values.len <= 1: return 0.0
  let average = mean(values)
  for value in values: result += (value - average) * (value - average)
  sqrt(result / (values.len - 1).float)

proc groupKey(dataset, variant: string; level: int): string =
  dataset & "\t" & variant & "\t" & $level

proc summarize(path: string) =
  var parser: CsvParser
  parser.open(path)
  defer: parser.close()
  if not parser.readRow():
    raise newException(ValueError, "empty CSV: " & path)
  var columns = initTable[string, int]()
  for index, name in parser.row: columns[name] = index
  for required in ["dataset", "input_bytes", "variant", "level", "wall_s",
                   "mib_s", "compression_ratio", "exit_code"]:
    if required notin columns:
      raise newException(ValueError, "missing CSV column: " & required)
  var groups = initTable[string, SummaryGroup]()
  while parser.readRow():
    template value(name: string): string = parser.row[columns[name]]
    let dataset = value("dataset")
    let variant = value("variant")
    let level = parseInt(value("level"))
    let key = groupKey(dataset, variant, level)
    if key notin groups:
      groups[key] = SummaryGroup(dataset: dataset, variant: variant,
        level: level, inputBytes: parseBiggestUInt(value("input_bytes")).uint64)
    var group = groups[key]
    if parseInt(value("exit_code")) == 0:
      inc group.successfulRuns
      group.walls.add(parseFloat(value("wall_s")))
      group.throughputs.add(parseFloat(value("mib_s")))
      group.ratios.add(parseFloat(value("compression_ratio")))
    else:
      inc group.failedRuns
    groups[key] = group
  var ordered: seq[SummaryGroup]
  for _, group in groups: ordered.add(group)
  ordered.sort(proc(a, b: SummaryGroup): int =
    result = cmp(a.dataset, b.dataset)
    if result == 0: result = cmp(a.level, b.level)
    if result == 0: result = cmp(a.variant, b.variant))
  var gzipWall = initTable[string, float]()
  var pigzWall = initTable[string, float]()
  for group in ordered:
    if group.walls.len == 0: continue
    let key = group.dataset & "\t" & $group.level
    if group.variant == "gzip": gzipWall[key] = mean(group.walls)
    if group.variant == "pigz-p1": pigzWall[key] = mean(group.walls)
  echo "dataset,variant,level,input_bytes,runs,failed_runs,mean_wall_s," &
       "sd_wall_s,mean_mib_s,mean_compression_ratio,speedup_vs_gzip," &
       "speedup_vs_pigz_p1"
  for group in ordered:
    let key = group.dataset & "\t" & $group.level
    if group.walls.len == 0:
      echo &"{csv(group.dataset)},{group.variant},{group.level}," &
           &"{group.inputBytes},0,{group.failedRuns},,,,,,"
      continue
    let wall = mean(group.walls)
    let gzipSpeedup =
      if key in gzipWall: &"{gzipWall[key] / wall:.4f}" else: ""
    let pigzSpeedup =
      if key in pigzWall: &"{pigzWall[key] / wall:.4f}" else: ""
    echo &"{csv(group.dataset)},{group.variant},{group.level}," &
         &"{group.inputBytes},{group.successfulRuns},{group.failedRuns}," &
         &"{wall:.6f},{stddev(group.walls):.6f}," &
         &"{mean(group.throughputs):.3f},{mean(group.ratios):.6f}," &
         gzipSpeedup & "," & pigzSpeedup

when isMainModule:
  var options: BenchOptions
  try:
    options = parseArgs()
    if options.summaryPath.len > 0:
      summarize(options.summaryPath)
      quit(0)
    createDir(options.workDir)
    let hasGzip = options.includeGzip and findExe("gzip").len > 0
    let hasPigz = options.includePigz and findExe("pigz").len > 0
    if options.includeGzip and not hasGzip:
      raise newException(IOError,
        "gzip was not found; install it or pass --no-gzip")
    if options.requirePigz and not hasPigz:
      raise newException(IOError, "pigz is required but was not found")
    if options.includePigz and not hasPigz:
      stderr.writeLine("bench_writer: pigz not found; skipping pigz baselines")
    var variants = @["gzfast"]
    if hasGzip: variants.add("gzip")
    if hasPigz: variants.add("pigz-p1")
    var datasets: seq[Dataset]
    for name in options.datasets:
      stderr.writeLine("bench_writer: generating " & name & " (" &
                       $options.size & " bytes)")
      datasets.add(generateDataset(name, options.workDir, options.size))
    defer:
      if not options.keepData:
        for dataset in datasets: cleanup(dataset.path)
    printHeader()
    for dataset in datasets:
      for _ in 0 ..< options.warmups:
        for level in benchLevels:
          for variant in variants:
            discard runVariant(dataset, variant, level, options.workDir)
      for iteration in 1 .. options.repeats:
        for level in benchLevels:
          for variant in variants:
            printRun(dataset, variant, level, iteration,
                     runVariant(dataset, variant, level, options.workDir))
  except CatchableError as error:
    stderr.writeLine("bench_writer: " & error.msg)
    quit(2)

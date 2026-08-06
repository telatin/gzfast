## FASTQ-oriented benchmark harness.
##
## This measures gzfast through the library API so path selection, CRC,
## decoded byte counts and memory accounting are available in every row.
## The optional gunzip/pigz baselines are wall-time only.

import std/[algorithm, math, monotimes, os, osproc, parsecsv, parseopt,
            strformat, strutils, tables, times]

import gzfast
import gzfast/private/zlib_api

when defined(posix):
  import std/posix

const
  defaultThreads = @[1, 4, 8]
  devNull = when defined(windows): "NUL" else: "/dev/null"

type
  BenchOptions = object
    repeats: int
    warmups: int
    includeGunzip: bool
    includePigz: bool
    includeMarker: bool
    summaryPath: string
    threads: seq[int]
    files: seq[string]

  UsageSample = object
    user: float
    system: float

  BenchRow = object
    dataset: string
    compressedBytes: uint64
    variant: string
    threads: int
    markerEnabled: bool
    paths: string
    decodedBytes: uint64
    members: int
    wall: float
    cpu: float
    user: float
    system: float
    mib: float
    hasCpu: bool
    hasUser: bool
    hasSystem: bool
    hasMib: bool
    peakWorkers: int
    peakBufferedBytes: uint64
    exitCode: int

  SummaryGroup = object
    dataset: string
    compressedBytes: uint64
    decodedBytes: uint64
    members: int
    variant: string
    threads: int
    markerEnabled: bool
    paths: seq[string]
    wallValues: seq[float]
    cpuValues: seq[float]
    userValues: seq[float]
    systemValues: seq[float]
    mibValues: seq[float]
    peakWorkers: int
    peakBufferedBytes: uint64
    failedRuns: int

proc usageNow(): UsageSample =
  when defined(posix):
    var usage: Rusage
    discard getrusage(RUSAGE_SELF, addr usage)
    result.user = usage.ru_utime.tv_sec.float +
      usage.ru_utime.tv_usec.float / 1e6
    result.system = usage.ru_stime.tv_sec.float +
      usage.ru_stime.tv_usec.float / 1e6
  else:
    result.user = cpuTime()
    result.system = 0.0

proc `-`(finish, start: UsageSample): UsageSample =
  UsageSample(user: finish.user - start.user,
              system: finish.system - start.system)

proc pathName(paths: set[DecodePath]): string =
  for path in paths:
    if result.len > 0: result.add('+')
    result.add($path)
  if result.len == 0:
    result = "none"

proc csv(s: string): string =
  result = "\""
  for c in s:
    if c == '"': result.add("\"\"")
    else: result.add(c)
  result.add('"')

proc field(row: CsvRow; index: Table[string, int]; name: string): string =
  let column = index[name]
  if column < row.len: row[column]
  else: ""

proc parseUint64Field(value, name: string): uint64 =
  let stripped = value.strip()
  if stripped.len == 0:
    return 0
  try:
    result = uint64(parseBiggestUInt(stripped))
  except ValueError:
    raise newException(ValueError, "invalid " & name & ": " & value)

proc parseIntField(value, name: string): int =
  let stripped = value.strip()
  if stripped.len == 0:
    return 0
  try:
    result = parseInt(stripped)
  except ValueError:
    raise newException(ValueError, "invalid " & name & ": " & value)

proc parseFloatField(value, name: string): tuple[hasValue: bool; value: float] =
  let stripped = value.strip()
  if stripped.len == 0:
    return (false, 0.0)
  try:
    result = (true, parseFloat(stripped))
  except ValueError:
    raise newException(ValueError, "invalid " & name & ": " & value)

proc parseBoolField(value, name: string): bool =
  case value.strip().toLowerAscii()
  of "true", "1", "yes":
    true
  of "false", "0", "no", "":
    false
  else:
    raise newException(ValueError, "invalid " & name & ": " & value)

proc addUnique(values: var seq[string]; value: string) =
  for existing in values:
    if existing == value:
      return
  values.add(value)

proc joined(values: seq[string]): string =
  for value in values:
    if result.len > 0:
      result.add('|')
    result.add(value)

proc mean(values: seq[float]): float =
  for value in values:
    result += value
  result /= values.len.float

proc stddev(values: seq[float]): float =
  if values.len <= 1:
    return 0.0
  let avg = mean(values)
  for value in values:
    result += (value - avg) * (value - avg)
  result = sqrt(result / (values.len - 1).float)

proc minValue(values: seq[float]): float =
  result = values[0]
  for value in values:
    if value < result:
      result = value

proc maxValue(values: seq[float]): float =
  result = values[0]
  for value in values:
    if value > result:
      result = value

proc fmtFloat(value: float; digits = 6): string =
  value.formatFloat(ffDecimal, digits)

proc fmtMaybe(values: seq[float]; digits = 6): string =
  if values.len == 0:
    ""
  else:
    fmtFloat(mean(values), digits)

proc fmtRatio(value: float): string =
  if value <= 0.0:
    ""
  else:
    fmtFloat(value, 4)

proc groupKey(dataset, variant: string): string =
  dataset & "\t" & variant

proc datasetThreadKey(dataset: string; threads: int): string =
  dataset & "\t" & $threads

proc isExternalVariant(variant: string): bool =
  variant == "gunzip" or variant.startsWith("pigz-")

proc loadBenchRows(path: string): seq[BenchRow] =
  var parser: CsvParser
  parser.open(path)
  defer: parser.close()

  if not parser.readRow():
    raise newException(ValueError, "empty CSV: " & path)

  var index = initTable[string, int]()
  for column, name in parser.row:
    index[name] = column

  let required = ["dataset", "compressed_bytes", "variant", "threads",
                  "marker_enabled", "paths", "decoded_bytes", "members",
                  "wall_s", "cpu_s", "user_s", "system_s", "mib_s",
                  "peak_workers", "peak_buffered_bytes", "exit_code"]
  for name in required:
    if name notin index:
      raise newException(ValueError, "missing CSV column: " & name)

  while parser.readRow():
    var row: BenchRow
    row.dataset = field(parser.row, index, "dataset")
    row.compressedBytes =
      parseUint64Field(field(parser.row, index, "compressed_bytes"),
                       "compressed_bytes")
    row.variant = field(parser.row, index, "variant")
    row.threads = parseIntField(field(parser.row, index, "threads"),
                                "threads")
    row.markerEnabled =
      parseBoolField(field(parser.row, index, "marker_enabled"),
                     "marker_enabled")
    row.paths = field(parser.row, index, "paths")
    row.decodedBytes =
      parseUint64Field(field(parser.row, index, "decoded_bytes"),
                       "decoded_bytes")
    row.members = parseIntField(field(parser.row, index, "members"),
                                "members")
    let wall = parseFloatField(field(parser.row, index, "wall_s"), "wall_s")
    if not wall.hasValue:
      raise newException(ValueError, "missing wall_s for " & row.variant)
    row.wall = wall.value
    let cpu = parseFloatField(field(parser.row, index, "cpu_s"), "cpu_s")
    row.hasCpu = cpu.hasValue
    row.cpu = cpu.value
    let userTime = parseFloatField(field(parser.row, index, "user_s"),
                                   "user_s")
    row.hasUser = userTime.hasValue
    row.user = userTime.value
    let systemTime = parseFloatField(field(parser.row, index, "system_s"),
                                     "system_s")
    row.hasSystem = systemTime.hasValue
    row.system = systemTime.value
    let mib = parseFloatField(field(parser.row, index, "mib_s"), "mib_s")
    row.hasMib = mib.hasValue
    row.mib = mib.value
    row.peakWorkers =
      parseIntField(field(parser.row, index, "peak_workers"), "peak_workers")
    row.peakBufferedBytes =
      parseUint64Field(field(parser.row, index, "peak_buffered_bytes"),
                       "peak_buffered_bytes")
    row.exitCode = parseIntField(field(parser.row, index, "exit_code"),
                                 "exit_code")
    result.add(row)

proc summarizeCsv(path: string) =
  let rows = loadBenchRows(path)
  if rows.len == 0:
    raise newException(ValueError, "CSV has no benchmark rows: " & path)

  var groups = initTable[string, SummaryGroup]()
  for row in rows:
    let key = groupKey(row.dataset, row.variant)
    if key notin groups:
      groups[key] = SummaryGroup(dataset: row.dataset,
                                 compressedBytes: row.compressedBytes,
                                 variant: row.variant,
                                 threads: row.threads,
                                 markerEnabled: row.markerEnabled)
    var group = groups[key]
    if row.compressedBytes > group.compressedBytes:
      group.compressedBytes = row.compressedBytes
    if row.decodedBytes > group.decodedBytes:
      group.decodedBytes = row.decodedBytes
    if row.members > group.members:
      group.members = row.members
    group.paths.addUnique(row.paths)
    group.wallValues.add(row.wall)
    let hasResourceMetrics = not row.variant.isExternalVariant()
    if row.hasCpu and hasResourceMetrics: group.cpuValues.add(row.cpu)
    if row.hasUser and hasResourceMetrics: group.userValues.add(row.user)
    if row.hasSystem and hasResourceMetrics:
      group.systemValues.add(row.system)
    if row.hasMib and hasResourceMetrics: group.mibValues.add(row.mib)
    if row.peakWorkers > group.peakWorkers:
      group.peakWorkers = row.peakWorkers
    if row.peakBufferedBytes > group.peakBufferedBytes:
      group.peakBufferedBytes = row.peakBufferedBytes
    if row.exitCode != 0:
      inc group.failedRuns
    groups[key] = group

  var summaries: seq[SummaryGroup]
  for _, group in groups:
    summaries.add(group)
  summaries.sort(proc(a, b: SummaryGroup): int =
    result = cmp(a.dataset, b.dataset)
    if result == 0:
      result = cmp(a.variant, b.variant)
  )

  var gunzipByDataset = initTable[string, float]()
  var bestDefaultByDataset = initTable[string, float]()
  var defaultByDatasetThread = initTable[string, float]()
  for group in summaries:
    let avgWall = mean(group.wallValues)
    if group.variant == "gunzip":
      gunzipByDataset[group.dataset] = avgWall
    elif group.variant.startsWith("gzfast") and not group.markerEnabled:
      if group.dataset notin bestDefaultByDataset or
          avgWall < bestDefaultByDataset[group.dataset]:
        bestDefaultByDataset[group.dataset] = avgWall
      defaultByDatasetThread[datasetThreadKey(group.dataset, group.threads)] =
        avgWall

  echo "dataset,compressed_bytes,decoded_bytes,members,variant,runs," &
       "failed_runs,threads,marker_enabled,paths,mean_wall_s,sd_wall_s," &
       "min_wall_s,max_wall_s,mean_cpu_s,mean_user_s,mean_system_s," &
       "mean_mib_s,peak_workers,peak_buffered_bytes,speedup_vs_gunzip," &
       "speedup_vs_best_default,marker_wall_ratio_vs_default"
  for group in summaries:
    let avgWall = mean(group.wallValues)
    var speedupGunzip = ""
    if group.dataset in gunzipByDataset:
      speedupGunzip = fmtRatio(gunzipByDataset[group.dataset] / avgWall)
    var speedupBestDefault = ""
    if group.dataset in bestDefaultByDataset:
      speedupBestDefault =
        fmtRatio(bestDefaultByDataset[group.dataset] / avgWall)
    var markerRatio = ""
    if group.markerEnabled:
      let defaultKey = datasetThreadKey(group.dataset, group.threads)
      if defaultKey in defaultByDatasetThread:
        markerRatio = fmtRatio(avgWall / defaultByDatasetThread[defaultKey])

    echo &"{csv(group.dataset)},{group.compressedBytes}," &
         &"{group.decodedBytes},{group.members},{group.variant}," &
         &"{group.wallValues.len},{group.failedRuns},{group.threads}," &
         &"{group.markerEnabled},{csv(joined(group.paths))}," &
         &"{fmtFloat(avgWall)},{fmtFloat(stddev(group.wallValues))}," &
         &"{fmtFloat(minValue(group.wallValues))}," &
         &"{fmtFloat(maxValue(group.wallValues))}," &
         &"{fmtMaybe(group.cpuValues)},{fmtMaybe(group.userValues)}," &
         &"{fmtMaybe(group.systemValues)},{fmtMaybe(group.mibValues, 3)}," &
         &"{group.peakWorkers},{group.peakBufferedBytes}," &
         &"{speedupGunzip},{speedupBestDefault},{markerRatio}"

proc parseThreads(value: string): seq[int] =
  for part in value.split(','):
    let stripped = part.strip()
    if stripped.len == 0: continue
    let parsed = parseInt(stripped)
    if parsed <= 0:
      raise newException(ValueError, "threads must be positive: " & stripped)
    result.add(parsed)
  if result.len == 0:
    raise newException(ValueError, "no thread counts given")

proc parseArgs(): BenchOptions =
  result.repeats = 3
  result.warmups = 1
  result.includeGunzip = true
  result.includePigz = true
  result.includeMarker = true
  result.threads = defaultThreads
  var p = initOptParser(commandLineParams(),
    shortNoVal = {'h'},
    longNoVal = @["help", "no-gunzip", "no-pigz", "no-marker"])
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdArgument:
      result.files.add(p.key)
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        echo "usage: bench_fastq [--repeat N] [--warmup N] " &
          "[--threads 1,4,8] [--no-gunzip] [--no-pigz] " &
          "[--no-marker] FILE..."
        echo "       bench_fastq --summary RESULTS.csv"
        quit(0)
      of "summary":
        if p.val.len == 0:
          raise newException(ValueError, "--summary requires a CSV path")
        result.summaryPath = p.val
      of "repeat":
        result.repeats = parseInt(p.val)
      of "warmup":
        result.warmups = parseInt(p.val)
      of "threads":
        result.threads = parseThreads(p.val)
      of "no-gunzip":
        result.includeGunzip = false
      of "no-pigz":
        result.includePigz = false
      of "no-marker":
        result.includeMarker = false
      else:
        raise newException(ValueError, "unknown option: --" & p.key)
  if result.repeats <= 0:
    raise newException(ValueError, "--repeat must be positive")
  if result.warmups < 0:
    raise newException(ValueError, "--warmup must be >= 0")
  if result.summaryPath.len > 0:
    if result.files.len > 0:
      raise newException(ValueError, "--summary does not accept input files")
    return
  if result.files.len == 0:
    raise newException(ValueError, "no input files given")

proc runGunzip(path: string): tuple[wall: float; exitCode: int] =
  let wallStart = getMonoTime()
  result.exitCode = execShellCmd("gunzip -c " & quoteShell(path) &
                                 " > " & devNull)
  result.wall = (getMonoTime() - wallStart).inNanoseconds.float / 1e9

proc runPigz(path: string; threads: int): tuple[wall: float; exitCode: int] =
  let wallStart = getMonoTime()
  result.exitCode = execShellCmd("pigz -dc -p " & $threads & " " &
                                 quoteShell(path) & " > " & devNull)
  result.wall = (getMonoTime() - wallStart).inNanoseconds.float / 1e9

proc runGzfast(path: string; threads: int; marker: bool):
    tuple[wall: float; cpu: UsageSample; bytes: uint64; crc: uint32;
          report: DecodeReport] =
  var config = defaultGzFastConfig()
  config.threads = threads
  config.enableMarkerPath = marker
  let usageStart = usageNow()
  let wallStart = getMonoTime()
  let input = initGzFastDecoder(config).open(path)
  var buffer = newString(1024 * 1024)
  while true:
    let count = input.readData(addr buffer[0], buffer.len)
    if count == 0: break
    result.crc = gzCrc32(result.crc, cast[ptr byte](addr buffer[0]),
                         csize_t(count))
    result.bytes += uint64(count)
  result.report = input.finish()
  input.close()
  result.wall = (getMonoTime() - wallStart).inNanoseconds.float / 1e9
  result.cpu = usageNow() - usageStart
  doAssert result.report.crcVerified
  doAssert result.report.decompressedBytes == result.bytes

proc throughput(bytes: uint64; wall: float): float =
  if wall <= 0.0: 0.0
  else: (bytes.float / (1024.0 * 1024.0)) / wall

proc printHeader() =
  echo "dataset,compressed_bytes,variant,iteration,threads,marker_enabled," &
       "paths,decoded_bytes,members,wall_s,cpu_s,user_s,system_s,mib_s," &
       "peak_workers,peak_buffered_bytes,crc32,exit_code"

proc printExternal(path: string; compressedBytes: uint64; variant: string;
                   iteration, threads: int; wall: float; exitCode: int) =
  echo &"{csv(path.lastPathPart)},{compressedBytes},{variant},{iteration}," &
       &"{threads},false,external,0,0,{wall:.6f},,,,,0,0,0,{exitCode}"

proc printGzfast(path: string; compressedBytes: uint64; variant: string;
                 iteration, threads: int; marker: bool;
                 run: tuple[wall: float; cpu: UsageSample; bytes: uint64;
                            crc: uint32; report: DecodeReport]) =
  let cpuTotal = run.cpu.user + run.cpu.system
  echo &"{csv(path.lastPathPart)},{compressedBytes},{variant},{iteration}," &
       &"{threads},{marker},{pathName(run.report.pathsUsed)}," &
       &"{run.bytes},{run.report.memberCount},{run.wall:.6f}," &
       &"{cpuTotal:.6f},{run.cpu.user:.6f},{run.cpu.system:.6f}," &
       &"{throughput(run.bytes, run.wall):.3f},{run.report.peakWorkers}," &
       &"{run.report.peakBufferedBytes},{run.crc},0"

when isMainModule:
  var options: BenchOptions
  try:
    options = parseArgs()
  except ValueError as error:
    stderr.writeLine("bench_fastq: " & error.msg)
    quit(2)

  if options.summaryPath.len > 0:
    try:
      summarizeCsv(options.summaryPath)
    except CatchableError as error:
      stderr.writeLine("bench_fastq: " & error.msg)
      quit(2)
    quit(0)

  printHeader()
  let hasGunzip = options.includeGunzip and findExe("gunzip").len > 0
  let hasPigz = options.includePigz and findExe("pigz").len > 0
  for path in options.files:
    let compressedBytes = uint64(getFileSize(path))
    for _ in 0 ..< options.warmups:
      if hasGunzip:
        discard runGunzip(path)
      if hasPigz:
        for threads in options.threads:
          discard runPigz(path, threads)
      for threads in options.threads:
        discard runGzfast(path, threads, marker = false)
      if options.includeMarker:
        for threads in options.threads:
          if threads > 1:
            discard runGzfast(path, threads, marker = true)

    for iteration in 1 .. options.repeats:
      if hasGunzip:
        let gunzip = runGunzip(path)
        printExternal(path, compressedBytes, "gunzip", iteration, 0,
                      gunzip.wall, gunzip.exitCode)
      if hasPigz:
        for threads in options.threads:
          let pigz = runPigz(path, threads)
          printExternal(path, compressedBytes, "pigz-t" & $threads,
                        iteration, threads, pigz.wall, pigz.exitCode)
      for threads in options.threads:
        let run = runGzfast(path, threads, marker = false)
        printGzfast(path, compressedBytes,
                    "gzfast-t" & $threads, iteration, threads,
                    false, run)
      if options.includeMarker:
        for threads in options.threads:
          if threads <= 1: continue
          let run = runGzfast(path, threads, marker = true)
          printGzfast(path, compressedBytes,
                      "gzfast-t" & $threads & "-marker", iteration,
                      threads, true, run)

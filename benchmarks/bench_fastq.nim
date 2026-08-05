## FASTQ-oriented benchmark harness.
##
## This measures gzfast through the library API so path selection, CRC,
## decoded byte counts and memory accounting are available in every row.
## The optional gunzip baseline is wall-time only.

import std/[monotimes, os, osproc, parseopt, strformat, strutils, times]

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
    includeMarker: bool
    threads: seq[int]
    files: seq[string]

  UsageSample = object
    user: float
    system: float

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
  result.includeMarker = true
  result.threads = defaultThreads
  var p = initOptParser(commandLineParams(),
    shortNoVal = {'h'},
    longNoVal = @["help", "no-gunzip", "no-marker"])
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
          "[--threads 1,4,8] [--no-gunzip] [--no-marker] FILE..."
        quit(0)
      of "repeat":
        result.repeats = parseInt(p.val)
      of "warmup":
        result.warmups = parseInt(p.val)
      of "threads":
        result.threads = parseThreads(p.val)
      of "no-gunzip":
        result.includeGunzip = false
      of "no-marker":
        result.includeMarker = false
      else:
        raise newException(ValueError, "unknown option: --" & p.key)
  if result.repeats <= 0:
    raise newException(ValueError, "--repeat must be positive")
  if result.warmups < 0:
    raise newException(ValueError, "--warmup must be >= 0")
  if result.files.len == 0:
    raise newException(ValueError, "no input files given")

proc runGunzip(path: string): tuple[wall: float; exitCode: int] =
  let wallStart = getMonoTime()
  result.exitCode = execShellCmd("gunzip -c " & quoteShell(path) &
                                 " > " & devNull)
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

proc printGunzip(path: string; compressedBytes: uint64; iteration: int;
                 wall: float; exitCode: int) =
  echo &"{csv(path.lastPathPart)},{compressedBytes},gunzip,{iteration},0," &
       &"false,external,0,0,{wall:.6f},,,," &
       &"0,0,0,{exitCode}"

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

  printHeader()
  for path in options.files:
    let compressedBytes = uint64(getFileSize(path))
    for _ in 0 ..< options.warmups:
      if options.includeGunzip and findExe("gunzip").len > 0:
        discard runGunzip(path)
      for threads in options.threads:
        discard runGzfast(path, threads, marker = false)
      if options.includeMarker:
        for threads in options.threads:
          if threads > 1:
            discard runGzfast(path, threads, marker = true)

    for iteration in 1 .. options.repeats:
      if options.includeGunzip and findExe("gunzip").len > 0:
        let gunzip = runGunzip(path)
        printGunzip(path, compressedBytes, iteration,
                    gunzip.wall, gunzip.exitCode)
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

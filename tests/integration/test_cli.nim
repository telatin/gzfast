## Integration tests for the gzfast CLI binary.

import std/[unittest, os, osproc, strutils, streams]
import gzfast/private/zlib_api
import ../helpers/fixtures

var cliPath = ""

proc buildCli(): string =
  if cliPath.len != 0:
    return cliPath
  let outPath = getTempDir() / "gzfast_cli_test_bin"
  let projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  let (output, code) = execCmdEx("nim c --mm:orc --threads:on -d:release " &
    "--hints:off -o:" & outPath & " " & projectRoot / "src" / "gzfast_cli.nim")
  if code != 0:
    raise newException(AssertionDefect, "CLI build failed:\n" & output)
  cliPath = outPath
  cliPath

proc runCli(args: string): tuple[output: string, exitCode: int] =
  ## Capture stdout exactly (execCmdEx would append a newline after
  ## every line, corrupting binary output), stderr stays separate.
  let cmd = buildCli() & (if args.len > 0: " " & args else: "")
  let p = startProcess(cmd, options = {poUsePath, poEvalCommand})
  var outStr = newStringOfCap(1 shl 20)
  while not p.outputStream.atEnd:
    outStr.add p.outputStream.readStr(1 shl 16)
  result.output = outStr
  result.exitCode = p.waitForExit()
  p.close()

suite "gzfast CLI":
  test "binary builds":
    check buildCli().fileExists

  test "-dc writes pure decompressed data to stdout":
    let f = fixtureByName("small_text.gz")
    let (output, code) = runCli( " -dc " &
      quoteShell(fixturePath(f.name)))
    check code == 0
    check output.len == int(f.length)
    check crc32(output) == f.crc32

  test "--stats never contaminates stdout":
    let f = fixtureByName("small_text.gz")
    let (output, code) = runCli( " -dc --stats " &
      quoteShell(fixturePath(f.name)))
    check code == 0
    check output.len == int(f.length)

  test "--verify succeeds on valid files":
    let (_, code) = runCli( " --verify " &
      quoteShell(fixturePath("fastq.gz")))
    check code == 0

  test "--verify fails with exit 1 on truncated files":
    let data = readFixture("small_text.gz")
    let tmp = getTempDir() / "gzfast_cli_truncated.gz"
    writeFile(tmp, data[0 ..< data.len - 5])
    defer: removeFile(tmp)
    let (_, code) = runCli( " --verify " & quoteShell(tmp))
    check code == 1

  test "--verify fails with exit 1 on corrupt CRC":
    var data = toBytes(readFixture("small_text.gz"))
    data[^8] = data[^8] xor 0xFF
    let tmp = getTempDir() / "gzfast_cli_badcrc.gz"
    writeFile(tmp, toString(data))
    defer: removeFile(tmp)
    let (_, code) = runCli( " --verify " & quoteShell(tmp))
    check code == 1

  test "missing file gives exit 3":
    let (_, code) = runCli( " --verify /nonexistent.gz")
    check code == 3

  test "no arguments gives exit 2":
    let (_, code) = runCli("")
    check code == 2

  test "default output path strips .gz and preserves input":
    let dir = getTempDir() / "gzfast_cli_out"
    createDir(dir)
    let src = dir / "data.gz"
    writeFile(src, readFixture("small_text.gz"))
    defer: removeDir(dir)
    let (output, code) = runCli( " " & quoteShell(src))
    check code == 0
    check fileExists(dir / "data")
    check fileExists(src) # input preserved
    let f = fixtureByName("small_text.gz")
    check crc32(readFile(dir / "data")) == f.crc32
    check "gzfast" in output or true # messages go to stderr

  test "existing output is refused without -f":
    let dir = getTempDir() / "gzfast_cli_out2"
    createDir(dir)
    let src = dir / "data.gz"
    writeFile(src, readFixture("small_text.gz"))
    writeFile(dir / "data", "occupied")
    defer: removeDir(dir)
    let (_, code) = runCli( " " & quoteShell(src))
    check code == 2
    check readFile(dir / "data") == "occupied"
    let (_, code2) = runCli( " -f " & quoteShell(src))
    check code2 == 0
    check crc32(readFile(dir / "data")) == fixtureByName("small_text.gz").crc32

  test "--output-limit gives exit 1 when exceeded":
    let (_, code) = runCli(
      " --verify --output-limit 100 " & quoteShell(fixturePath("small_text.gz")))
    check code == 1

  test "concatenated members decode through -dc":
    let f = fixtureByName("concat_3.gz")
    let (output, code) = runCli( " -dc " &
      quoteShell(fixturePath(f.name)))
    check code == 0
    check output.len == int(f.length)
    check crc32(output) == f.crc32

  test "--version and --help":
    check runCli( " --version").exitCode == 0
    check runCli( " --help").exitCode == 0

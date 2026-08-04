## Package validation: pack the project, install it into a clean
## Nimble directory, compile a consumer program, and inspect the
## resulting binary for unwanted compression-library dependencies.
##
## Run via `nimble testPackage`.

import std/[os, osproc, strutils]

proc run(cmd: string; workdir = ""): tuple[output: string, exitCode: int] =
  let full = if workdir.len > 0: "cd " & quoteShell(workdir) & " && " & cmd
             else: cmd
  execCmdEx(full, options = {poUsePath, poStdErrToStdOut})

proc main() =
  let projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  let tmp = getTempDir() / "gzfast_pkgtest"
  removeDir(tmp)
  createDir(tmp)
  defer: removeDir(tmp)

  echo "[pkg] nimble pack"
  var r = run("nimble pack -y", projectRoot)
  doAssert r.exitCode == 0, r.output

  let archive = projectRoot / "gzfast-0.1.0.tar.gz"
  doAssert fileExists(archive), "no package archive produced"
  defer: removeFile(archive)

  # Extract the archive and install from the extracted package dir.
  let unpackDir = tmp / "unpack"
  createDir(unpackDir)
  r = run("tar -xzf " & quoteShell(archive), unpackDir)
  doAssert r.exitCode == 0, r.output
  let pkgDir = unpackDir / "gzfast-0.1.0"
  doAssert dirExists(pkgDir)

  let nimbleDir = tmp / "nimble"
  echo "[pkg] installing into clean nimble dir"
  r = run("nimble -y --nimbleDir:" & quoteShell(nimbleDir) & " install",
          pkgDir)
  doAssert r.exitCode == 0, r.output

  # A consumer Nimble package compiled against the installed one.
  let consumerDir = tmp / "consumer"
  createDir(consumerDir)
  writeFile(consumerDir / "consumer.nimble", """
version = "0.1.0"
author = "test"
description = "consumer"
license = "MIT"
bin = @["consumer"]
requires "nim >= 2.2.0", "gzfast"
""")
  writeFile(consumerDir / "consumer.nim", """
import gzfast
import std/os

let here = currentSourcePath().parentDir()
let f = openGzFast(here / "sample.gz")
var total = 0
var buf = newString(4096)
while true:
  let n = f.readData(addr buf[0], buf.len)
  if n == 0: break
  total += n
let report = f.finish()
f.close()
doAssert report.crcVerified
doAssert report.memberCount == 3
echo "consumer-ok ", total
""")
  let corpusDir = projectRoot / "tests" / "corpus"
  copyFile(corpusDir / "concat_3.gz", consumerDir / "sample.gz")

  echo "[pkg] compiling consumer"
  r = run("nimble -y --nimbleDir:" & quoteShell(nimbleDir) & " build",
          consumerDir)
  doAssert r.exitCode == 0, r.output

  echo "[pkg] running consumer"
  r = run(quoteShell(consumerDir / "consumer"))
  doAssert r.exitCode == 0, r.output
  doAssert "consumer-ok 52880" in r.output, r.output

  echo "[pkg] inspecting binary dependencies"
  when defined(macosx):
    r = run("otool -L " & quoteShell(consumerDir / "consumer"))
    doAssert r.exitCode == 0
    for line in r.output.splitLines:
      let l = line.strip()
      if l.endsWith(":") or l.contains("(architecture"):
        continue # the binary's own path header
      doAssert not l.contains("libz."), "unexpected dependency: " & l
      doAssert not l.contains("zlib"), "unexpected dependency: " & l
  elif defined(linux):
    r = run("ldd " & quoteShell(consumerDir / "consumer"))
    doAssert r.exitCode == 0
    for line in r.output.splitLines:
      doAssert not line.contains("libz."), "unexpected dependency: " & line
      doAssert not line.contains("zlib"), "unexpected dependency: " & line
  elif defined(windows):
    r = run("objdump -p " & quoteShell(consumerDir / "consumer"))
    if r.exitCode == 0:
      for line in r.output.splitLines:
        if line.contains("DLL Name"):
          doAssert not line.contains("zlib"), "unexpected DLL: " & line

  # Also verify the binary exports no raw zlib symbols.
  when not defined(windows):
    r = run("nm -g " & quoteShell(consumerDir / "consumer"))
    if r.exitCode == 0:
      for line in r.output.splitLines:
        if " T " in line or " D " in line or " B " in line:
          let sym = line.split(' ')[^1].strip(chars = {'_'})
          doAssert not (sym.startsWith("inflate") or sym == "crc32" or
            sym.startsWith("deflate") or sym == "zlibVersion"),
            "unprefixed zlib symbol leaked: " & line

  echo "[pkg] OK"

main()

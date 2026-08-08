# Package

version       = "0.2.1"
author        = "gzfast contributors"
description   = "Fast, verified gzip I/O with a bundled zlib (no system libraries required)"
license       = "MIT"
srcDir        = "src"
bin           = @["gzfast_cli"]
namedBin      = {"gzfast_cli": "gzfast"}.toTable()
installExt    = @["nim", "c", "h"]
skipDirs      = @["tests", "benchmarks", "fuzz", ".github"]

# Dependencies

requires "nim >= 2.2.0"

import std/[os, strutils]

task pack, "Create a Nimble package archive in the project root":
  let stage = "nimcache" / "gzfast-pack" / "gzfast-" & version
  if dirExists(stage):
    rmDir(stage)
  mkDir(stage)
  # Stage everything the install rules need, mirroring skipDirs.
  let skip = @["tests", "benchmarks", "fuzz", ".github", ".git",
               "nimcache", "docs", "rapidgzip", "rapidgzip-rust"]
  for kind, path in walkDir("."):
    let name = path.lastPathPart
    if name in skip or name.startsWith("."):
      continue
    case kind
    of pcDir:
      cpDir(path, stage / name)
    of pcFile:
      if name.endsWith(".tar.gz") or name == "gzfast":
        continue
      cpFile(path, stage / name)
    else:
      discard
  exec "tar -czf " & "gzfast-" & version & ".tar.gz -C " &
    quoteShell("nimcache" / "gzfast-pack") & " " & "gzfast-" & version
  echo "wrote gzfast-" & version & ".tar.gz"

# Tasks

task test, "Run the complete normal test suite":
  for t in ["unit/test_zlib_api", "unit/test_header", "unit/test_footer",
            "unit/test_source", "unit/test_buffers", "unit/test_deflate_bitreader",
            "unit/test_writer",
            "unit/test_deflate_huffman",
            "unit/test_deflate_structures",
            "unit/test_deflate_blockfinder",
            "unit/test_deflate_differential",
            "unit/test_marker_decode",
            "unit/test_marker_resolve",
            "unit/test_adaptive",
            "unit/test_sequential", "integration/test_api",
            "integration/test_cli", "integration/test_marker_path",
            "integration/test_large_stream",
            "corruption/test_matrix",
            ]:
    exec "nim c -r --mm:orc --threads:on -p:src --hints:off tests/" & t & ".nim"
  exec "nim c --mm:orc --hints:off -o:nimcache/run_with_timeout tests/helpers/run_with_timeout.nim"
  for t in ["concurrency/test_bounded_queue", "concurrency/test_workers",
            "concurrency/test_member_workers", "concurrency/test_public_stress"]:
    exec "nim c --mm:orc --threads:on -p:src --hints:off tests/" & t & ".nim"
    exec "nimcache/run_with_timeout 300000 tests/" & t

task testFast, "Run unit tests only":
  for t in ["unit/test_zlib_api", "unit/test_header", "unit/test_footer",
            "unit/test_source", "unit/test_buffers", "unit/test_deflate_bitreader",
            "unit/test_writer",
            "unit/test_deflate_huffman",
            "unit/test_deflate_structures",
            "unit/test_deflate_blockfinder",
            "unit/test_deflate_differential",
            "unit/test_marker_decode",
            "unit/test_marker_resolve",
            "unit/test_adaptive",
            "unit/test_sequential"]:
    exec "nim c -r --mm:orc --threads:on -p:src --hints:off tests/" & t & ".nim"

task testCi, "Run the push/PR confidence suite":
  exec "nimble testFast"
  for t in ["integration/test_api", "integration/test_cli"]:
    exec "nim c -r --mm:orc --threads:on -p:src --hints:off tests/" & t & ".nim"

task testSlow, "Run the extended/slow suite (currently the normal suite)":
  exec "nimble test"

task testRelease, "Run local pre-release validation":
  exec "nimble test"
  exec "nimble testSanitize"
  exec "nimble fuzzSmoke"
  exec "nimble testPackage"

task testAsan, "Run high-risk suites under AddressSanitizer":
  when defined(linux):
    for t in ["unit/test_zlib_api", "unit/test_source", "unit/test_buffers",
              "unit/test_deflate_bitreader", "unit/test_deflate_huffman",
              "unit/test_deflate_structures", "unit/test_writer",
              "unit/test_marker_decode",
              "unit/test_marker_resolve", "unit/test_sequential",
              "integration/test_marker_path", "corruption/test_matrix",
              "concurrency/test_bounded_queue", "concurrency/test_workers",
              "concurrency/test_member_workers"]:
      exec "nim c -r --mm:orc --threads:on -p:src --hints:off " &
        "--passC:-fsanitize=address --passC:-fno-omit-frame-pointer " &
        "--passL:-fsanitize=address tests/" & t & ".nim"
  else:
    echo "testAsan is supported on Linux only"

task testUbsan, "Run high-risk suites under UndefinedBehaviorSanitizer":
  when defined(linux):
    for t in ["unit/test_zlib_api", "unit/test_source", "unit/test_buffers",
              "unit/test_deflate_bitreader", "unit/test_deflate_huffman",
              "unit/test_deflate_structures", "unit/test_writer",
              "unit/test_marker_decode",
              "unit/test_marker_resolve", "unit/test_sequential",
              "integration/test_marker_path", "corruption/test_matrix",
              "concurrency/test_bounded_queue", "concurrency/test_workers",
              "concurrency/test_member_workers"]:
      # GCC/UBSan reports Nim-generated exception-flag checks as null
      # _Bool loads/stores. Keep the rest of UBSan fatal, but disable
      # that noisy sub-check for Nim C backend builds.
      exec "UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 " &
        "nim c -r --mm:orc --threads:on -p:src --hints:off " &
        "--passC:-fsanitize=undefined --passC:-fno-sanitize=null " &
        "--passC:-fno-sanitize-recover=undefined " &
        "--passC:-fno-omit-frame-pointer " &
        "--passL:-fsanitize=undefined tests/" & t & ".nim"
  else:
    echo "testUbsan is supported on Linux only"

task testSanitize, "Run ASan and UBSan suites":
  exec "nimble testAsan"
  exec "nimble testUbsan"

task fuzzSmoke, "Build fuzz harnesses and run the committed seed corpus":
  exec "nim c --threads:on --mm:orc -p:src --hints:off -o:nimcache/fuzz_header fuzz/fuzz_header.nim"
  exec "nim c --threads:on --mm:orc -p:src --hints:off -o:nimcache/fuzz_decode fuzz/fuzz_decode.nim"
  exec "nimcache/fuzz_header tests/corpus/*.gz"
  exec "nimcache/fuzz_decode tests/corpus/*.gz"

task testPackage, "Pack, install into a clean Nimble dir and compile a consumer":
  exec "nim c -r --mm:orc --hints:off tests/package/test_package.nim"

task bench, "Run benchmarks":
  exec "nim e benchmarks/run_benchmarks.nims"

task benchFastq, "Build the FASTQ benchmark harness":
  exec "nim c -d:release --threads:on --mm:orc -p:src --hints:off " &
       "-o:benchmarks/bench_fastq benchmarks/bench_fastq.nim"
  echo "run: benchmarks/bench_fastq FILE.fastq.gz [...]"
  echo "pigz: included automatically when pigz is on PATH; disable with --no-pigz"
  echo "modes: --modes api,cli-null,cli-file,pipe-wc"
  echo "marker: disabled by default; enable with --marker"
  echo "summarize: benchmarks/bench_fastq --summary fastq-bench.csv > fastq-summary.csv"

task benchWriter, "Build the gzip writer benchmark harness":
  exec "nim c -d:release --threads:on --mm:orc -p:src --hints:off " &
       "-o:benchmarks/bench_writer benchmarks/bench_writer.nim"
  echo "run: benchmarks/bench_writer --repeat 3 --warmup 1 > writer-bench.csv"
  echo "quick: benchmarks/bench_writer --size 8MiB --repeat 1 --warmup 0"
  echo "summarize: benchmarks/bench_writer --summary writer-bench.csv > writer-summary.csv"

task docs, "Generate API documentation":
  exec "nim doc --mm:orc --threads:on --project --outdir:docs src/gzfast.nim"

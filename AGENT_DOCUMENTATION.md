# Agent Guide for gzfast

This guide is for coding agents working on or consuming `gzfast`. It
summarizes the public API, build assumptions, correctness rules, and
validation commands that matter when making automated changes.

## Project Role

`gzfast` is a Nim library and CLI for gzip I/O:

- Verified gzip decompression with bounded memory.
- Parallel decompression where the input layout is independently
  decodable, such as BGZF or dense concatenated gzip members.
- Generic gzip writing through a streaming API.
- No system zlib runtime dependency. A private, symbol-prefixed zlib
  1.3.2 source subset is bundled and compiled into consumers.

Do not add dependencies on `-lz`, `dynlib`, `pkg-config`, CMake, Rust,
NASM, or system zlib headers.

## Requirements

- Nim >= 2.2.0.
- Use `--threads:on` for builds that may exercise parallel paths.
- ORC is the expected memory manager in project tests.

Typical compile command:

```bash
nim c -d:release --threads:on --mm:orc -p:src program.nim
```

## Public Import Surface

Consumers should normally use only:

```nim
import gzfast
```

The top-level module exports the supported public API. Avoid importing
`gzfast/private/*` or internal path/scheduler modules from application
code.

## Reading Gzip Files

Use `openGzFast` for path-based gzip input:

```nim
import gzfast

let input = openGzFast("reads.fastq.gz", threads = 8)
defer: input.close()

var buf = newString(1 shl 20)
while true:
  let n = input.readData(addr buf[0], buf.len)
  if n == 0:
    break
  # Use buf[0 ..< n].

let report = input.finish()
doAssert report.crcVerified
```

Important read semantics:

- `GzFastStream` is forward-only. Seeking is unsupported and raises.
- `finish()` verifies the complete gzip stream. If the caller has not
  read to EOF, it drains remaining decoded bytes internally and verifies
  headers, DEFLATE syntax, CRC32, ISIZE, and later members.
- `close()` before EOF cancels unread work. Use `finish()` first when
  verification matters.
- Output chunks are arbitrary byte chunks. They are not aligned to
  FASTA, FASTQ, line, or record boundaries.
- `openGzFast(path, threads = 1)` forces the sequential authoritative
  path.

For non-positional sources such as memory streams, pipes, or sockets,
use the sequential stream API:

```nim
import std/streams
import gzfast

let compressed = newStringStream(data)
let input = openGzFastSequential(compressed)
defer: input.close()
```

## Direct Decompression To Output

Use `decodeTo` or `decompressFile` when the caller only needs to write
decoded bytes out:

```nim
import gzfast

let decoder = initGzFastDecoder(threads = 8)
let report = decoder.decodeTo("reads.fastq.gz", stdout)
doAssert report.crcVerified

discard decompressFile("reads.fastq.gz", "reads.fastq")
```

Only the caller thread touches the output `Stream` or `File`.

## Writing Gzip Files

Use `GzFastWriter` for generic gzip output. It is not FASTA/FASTQ
specific and should be fed caller-owned batches.

```nim
import gzfast

var config = defaultGzFastWriteConfig()
config.level = 6              # 0..9
config.outputBufferSize = 1 shl 20

let output = openGzFastWriter("records.gz", config)
defer: output.close()

var outputBuffer = newString(4 * 1024 * 1024)
# Fill outputBuffer with many formatted records.
discard output.writeData(addr outputBuffer[0], outputBuffer.len)
```

Writer semantics:

- `writeData(w, data, len)` is the primary performance API. It accepts
  a pointer and length so callers can reuse multi-MiB buffers without
  allocating one string per record.
- On success, `writeData` returns `len`. Short output writes or deflate
  failures raise.
- `writeString`, `writeBytes`, and `writeLine` are convenience wrappers.
- `flush()` uses sync flush. It makes bytes visible to the underlying
  file but may hurt compression ratio if called often.
- `finish()` completes the gzip member, writes the trailer, flushes the
  file, and returns `GzipWriteReport`.
- `close()` is idempotent and calls `finish()` if needed.
- After `finish()` or `close()`, further writes raise.

Example report usage:

```nim
let report = output.finish()
doAssert report.uncompressedBytes > 0
echo report.crc32
output.close()
```

## Configuration

Reader config:

```nim
import std/options
import gzfast

var config = defaultGzFastConfig()
config.threads = 8
config.outputLimit = some(1'u64 shl 30)
config.memoryLimit = 512 * 1024 * 1024
let decoder = initGzFastDecoder(config)
```

Writer config:

```nim
import gzfast

var config = defaultGzFastWriteConfig()
config.level = 6
config.outputBufferSize = 1 shl 20
config.strategy = 0
config.validate()
```

Validation raises `GzFastConfigError`.

## Errors

Library failures use `GzFastError`, which inherits from `IOError`.
Inspect `kind` for classification:

- `geInputIo`
- `geOutputIo`
- `geInvalidHeader`
- `geInvalidDeflate`
- `geTruncatedInput`
- `geChecksumMismatch`
- `geSizeMismatch`
- `geOutputLimit`
- `geCancelled`
- `geInternal`

Decoder errors also carry the best known `compressedOffset` and
`memberIndex`.

Example:

```nim
try:
  let input = openGzFast("sample.gz")
  defer: input.close()
  discard input.finish()
except GzFastError as e:
  echo "gzfast error: ", e.kind, " member=", e.memberIndex
```

## CLI

Common commands:

```bash
gzfast -dc --threads 8 reads.fastq.gz > reads.fastq
gzfast --verify suspicious.gz
gzfast input.gz
gzfast -c input > input.gz
gzfast -c -o input.gz input
cat input | gzfast -c > input.gz
```

Exit codes:

- `0`: success
- `1`: corrupt or truncated gzip data
- `2`: usage error
- `3`: I/O error
- `4`: internal error

Progress and statistics go to stderr, never data written to stdout.

## Internal Architecture Rules For Agents

When modifying the library:

- Keep gzip framing in Nim.
- Keep raw inflate/deflate behind `src/vendor/gzfast_zlib_shim.[ch]`
  and `src/gzfast/private/zlib_api.nim`.
- Do not expose `z_stream` or zlib headers to public Nim APIs.
- Do not use zlib's `gzopen`, `gzread`, or `gzwrite` file API.
- Preserve symbol prefixing and package tests that check for no system
  zlib dependency.
- Keep memory bounded by config values; do not introduce whole-file
  buffering for normal decode or write paths.
- Treat `close()` operations as idempotent.
- Do not silently skip checksum verification when a read result is used
  for correctness-sensitive work. Call `finish()`.
- Preserve forward-only stream semantics.
- Avoid format-specific assumptions. gzfast is generic gzip I/O, not a
  FASTA/FASTQ parser.

## Validation Commands

Run focused tests for writer or zlib-shim changes:

```bash
nim c -r --mm:orc --threads:on -p:src --hints:off tests/unit/test_zlib_api.nim
nim c -r --mm:orc --threads:on -p:src --hints:off tests/unit/test_writer.nim
nim c -r --mm:orc --threads:on -p:src --hints:off tests/integration/test_api.nim
```

Run the normal project suite:

```bash
nimble testFast
nimble test
```

Run package validation before release or vendored-zlib changes:

```bash
nim c -r --mm:orc --hints:off tests/package/test_package.nim
```

Full release confidence can be expensive:

```bash
nimble testRelease
```

Build and run the deterministic writer benchmark when changing the writer,
vendored deflater, buffering, or CLI compression path:

```bash
nimble benchWriter
benchmarks/bench_writer --repeat 3 --warmup 1 > writer-bench.csv
benchmarks/bench_writer --summary writer-bench.csv > writer-summary.csv
```

This measures levels 1, 6, and 9 over generic text, pseudo-random, and
FASTQ-shaped data. It checks every compressed output by decoding it and
comparing source size and CRC32. Release measurements should use
`--require-pigz` so a missing `pigz -p1` baseline fails explicitly.

If running inside a restricted sandbox, direct Nim cache output into the
workspace:

```bash
nim c -r --mm:orc --threads:on -p:src --hints:off \
  --nimcache:nimcache/test_writer tests/unit/test_writer.nim
```

Some Nimble/package tests may need permission to write Nimble metadata
under the user's normal Nimble/cache directories.

## Minimal Consumer Examples

Read and verify:

```nim
import gzfast

let input = openGzFast("input.gz")
defer: input.close()
let plain = input.readAll()
let report = input.finish()
doAssert report.crcVerified
```

Write and read back:

```nim
import gzfast

let output = openGzFastWriter("output.gz")
discard output.writeString("hello\n")
let writeReport = output.finish()
output.close()

let input = openGzFast("output.gz")
defer: input.close()
doAssert input.readAll() == "hello\n"
discard input.finish()
doAssert writeReport.uncompressedBytes == 6
```

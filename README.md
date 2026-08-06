# gzfast

Fast, verified, multithreaded decompression of gzip files for Nim —
with **zero system library requirements**.

```nim
import gzfast

let input = openGzFast("reads.fastq.gz", threads = 8)
defer:
  input.close()

for line in input.lines:
  discard line

discard input.finish()
```

## Why gzfast?

* **No external dependencies.** A private copy of zlib 1.3.2 is bundled
  in the package and compiled into your application via Nim's
  `{.compile.}` mechanism. Installing and building needs nothing but
  Nim itself:

  ```bash
  nimble install gzfast
  nim c -d:release --threads:on myprogram.nim
  ```

  No `zlib-dev`, no `libz.so`, no `zlib1.dll`, no `pkg-config`,
  no CMake, no Rust, no NASM. The bundled zlib's symbols are prefixed
  (`gzfast_z_*`), so it never collides with another zlib in the same
  binary.
* **Verified streaming.** Reaching EOF (or calling `finish()`)
  guarantees the *entire* compressed input was validated: gzip headers,
  optional fields, DEFLATE syntax, and every member's CRC32 and ISIZE —
  including every member of concatenated gzip and BGZF.
* **Bounded memory.** Input, output and speculative buffers are all
  bounded; files far larger than RAM stream without growth. Backpressure
  slows decoding when the consumer is slow. An optional `outputLimit`
  guards against decompression bombs.
* **Multithreaded where it pays.** Path-based BGZF blocks and
  concatenated gzip members are decoded in parallel by default. The
  rapidgzip-style marker/window path for ordinary single-member gzip is
  implemented but currently opt-in because measured FASTQ workloads are
  still faster through the sequential zlib path.

## Requirements

* Nim >= 2.2.0, compiled with `--threads:on` for the parallel paths.
  ORC is the default and recommended memory manager.

## Usage

### Streaming reader

```nim
import gzfast

let input = openGzFast("reads.fastq.gz", threads = 8)
defer: input.close()

var buf = newString(1 shl 20)
while true:
  let n = input.readData(addr buf[0], buf.len)
  if n == 0: break
  # process buf[0 ..< n]

let report = input.finish()  # verifies the whole stream
```

`GzFastStream` is a normal `std/streams` Stream: `readData`, `readStr`,
`readLine`, `lines`, `atEnd`, `close` all work. It is **forward-only**:
seeking raises instead of silently restarting decompression. Output
chunks do not align to FASTQ lines or records.

`finish()` semantics: if EOF was already reached it returns the
completed report; otherwise it discards the remaining decoded output
while continuing to decode and **verify** the complete compressed
stream. `close()` before EOF cancels remaining work. `cancel()` stops
unread work immediately.

### Direct output (no intermediate queue)

```nim
import gzfast

let decoder = initGzFastDecoder(threads = 8)
let report = decoder.decodeTo("reads.fastq.gz", stdout)

# or one call file-to-file:
discard decompressFile("reads.fastq.gz", "reads.fastq")
```

Only the caller's thread touches the output object; it never needs to
be thread-safe.

### Non-positional sources (pipes, sockets, memory)

```nim
import gzfast
import std/streams

let input = openGzFastSequential(newStringStream(compressedData))
```

A non-positional compressed stream cannot expose arbitrary compressed
offsets to workers, so it always uses the authoritative sequential
backend. gzfast does not silently create temporary files.

### Limits

```nim
import std/options
import gzfast

var config = defaultGzFastConfig()
config.outputLimit = some(1'u64 shl 30)  # decompression-bomb guard
config.memoryLimit = 512 * 1024 * 1024   # approximate internal ceiling
let decoder = initGzFastDecoder(config)
```

### Experimental ordinary-gzip parallelism

Ordinary single-member `.gz` files, including most `FASTQ.gz` files, use
the optimized sequential zlib path by default even when `threads > 1`.
To benchmark the rapidgzip-style marker/window path explicitly:

```nim
var config = defaultGzFastConfig()
config.threads = 8
config.enableMarkerPath = true
let decoder = initGzFastDecoder(config)
```

or from the CLI:

```bash
gzfast -dc --threads 8 --marker-path reads.fastq.gz > /dev/null
```

### Command line

```bash
gzfast -dc --threads 8 reads.fastq.gz | downstream-tool
gzfast -dc --threads 8 --marker-path reads.fastq.gz > /dev/null
gzfast --verify suspicious.gz
gzfast big.gz            # writes ./big
```

Exit codes: `0` success, `1` corrupt/truncated data, `2` usage error,
`3` I/O error, `4` internal error. Progress and statistics always go to
stderr, never into decompressed stdout. `--stats` includes the selected
decode paths, peak worker count, wall/CPU time and decoded throughput.

## Current milestone status

| Path | Status |
|---|---|
| Verified sequential decoding (headers, CRC32, ISIZE, multi-member, output limit) | ✅ complete |
| Public API (`openGzFast`, `decodeTo`, `decompressFile`, `openGzFastSequential`) + CLI | ✅ complete |
| Vendored, symbol-prefixed zlib with package-install validation | ✅ complete |
| Positional source, shared buffers, bounded queues, worker pool and ordered coordinator | ✅ complete |
| BGZF and concatenated-member parallelism | ✅ complete |
| Pure-Nim bit reader, Huffman/dynamic/stored structures and block finder | ✅ complete |
| Marker decoder and exact marker-free zlib handoff | ✅ complete |
| Marker resolution and ordinary single-member gzip parallel path | ✅ complete |
| Corruption, cancellation, large-stream, fuzz and sanitizer hardening | ✅ complete |
| Profile-driven scalar optimization, BGZF grouping and benchmark automation | ✅ complete |

Path-based input selects the safest available route: BGZF, dense
independent members, then the sequential zlib path. The rolling
marker/window path for ordinary gzip is available only when
`enableMarkerPath` or `--marker-path` is set. Unsupported,
false-positive, oversized, fixed-only, or otherwise unsuitable marker
regions bridge through the authoritative sequential backend from the
last verified state.

## Guarantees and caveats

* Reading to EOF verifies the complete input; so does `finish()`.
  A stream dropped early has *not* verified the unread remainder.
* Decoded bytes may be delivered to the consumer before the final
  trailer check; if verification later fails, an error is raised at
  that point (standard streaming-integrity semantics).
* `threads` is a maximum budget, not a promise to spawn that many
  workers.
* Ordinary single-member gzip does not use the experimental marker path
  unless explicitly enabled.
* The compressed file must not be modified while decoding.

## Development

```bash
nimble test          # full normal suite
nimble testFast      # unit tests only
nimble testSlow      # extended suite
nimble testSanitize  # ASan/UBSan (Linux)
nimble fuzzSmoke     # build harnesses and run committed seeds
nimble testPackage   # pack, clean-room install, consumer build, ldd/otool check
nimble bench         # generated release benchmark matrix (CSV)
nimble benchFastq    # build benchmarks/bench_fastq for real FASTQ.gz files
nimble docs
```

For real FASTQ measurements:

```bash
nimble benchFastq
benchmarks/bench_fastq --repeat 3 --warmup 1 \
  --threads 1,4,8 sample.fastq.gz
benchmarks/bench_fastq --summary fastq-bench.csv > fastq-summary.csv
```

The FASTQ harness emits CSV rows for `gunzip`, gzfast default thread
budgets and marker-path opt-in variants. It records file sizes,
`pathsUsed`, decoded bytes, members, wall/user/system time, throughput,
peak workers, peak buffered bytes and CRC32 for gzfast rows.
`--summary` reads a captured harness CSV and emits one aggregate CSV row
per dataset/variant with mean/stdev/min/max wall time, resource means,
speedup versus `gunzip`, speedup versus the best default gzfast run for
that dataset, and marker/default same-thread wall-time ratios.

See `ARCHITECTURE.md` for the design, `PROJECT.md` for the full
implementation brief, `UPSTREAM.md` for pinned upstream references,
`benchmarks/PROFILE.md` for measured optimization results, and
`THIRD_PARTY_NOTICES.md` for licences of derived/vendored code.

## License

MIT (gzfast itself). The vendored zlib 1.3.2 is under the zlib license;
see `THIRD_PARTY_NOTICES.md`.
# gzfast

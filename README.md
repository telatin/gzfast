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
* **Multithreaded.** Path-based input is decoded in parallel
  (BGZF blocks, concatenated members, and rapidgzip-style
  marker/window parallelism for ordinary gzip are rolled out across
  milestones — see the status table below).

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

### Command line

```bash
gzfast -dc --threads 8 reads.fastq.gz | downstream-tool
gzfast --verify suspicious.gz
gzfast big.gz            # writes ./big
```

Exit codes: `0` success, `1` corrupt/truncated data, `2` usage error,
`3` I/O error, `4` internal error. Progress and statistics always go to
stderr, never into decompressed stdout.

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

Path-based input selects the safest available parallel route: BGZF,
dense independent members, then the rolling marker/window path for
ordinary gzip. Unsupported, false-positive, oversized, fixed-only, or
otherwise unsuitable regions bridge through the authoritative sequential
backend from the last verified state.

## Guarantees and caveats

* Reading to EOF verifies the complete input; so does `finish()`.
  A stream dropped early has *not* verified the unread remainder.
* Decoded bytes may be delivered to the consumer before the final
  trailer check; if verification later fails, an error is raised at
  that point (standard streaming-integrity semantics).
* `threads` is a maximum budget, not a promise to spawn that many
  workers.
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
nimble docs
```

See `ARCHITECTURE.md` for the design, `PROJECT.md` for the full
implementation brief, `UPSTREAM.md` for pinned upstream references,
`benchmarks/PROFILE.md` for measured optimization results, and
`THIRD_PARTY_NOTICES.md` for licences of derived/vendored code.

## License

MIT (gzfast itself). The vendored zlib 1.3.2 is under the zlib license;
see `THIRD_PARTY_NOTICES.md`.
# gzfast

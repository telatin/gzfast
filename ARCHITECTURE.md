# gzfast architecture

This document describes the implemented design. It is updated whenever
ownership or scheduling behaviour changes (PROJECT.md coding rule 20).

## Layers

```text
Compressed source
        │
        ▼
Framing and path selection
        │
        ▼
Bounded parallel worker tasks        (milestones 4+)
        │
        ▼
Ordered coordinator                  (milestones 4+)
        │
        ▼
File / Stream / bounded reader queue
```

## Implemented today (milestones 0–10)

### Vendored zlib backend (`src/vendor/`, `src/gzfast/private/`)

* zlib 1.3.2 sources are compiled into the consuming application via
  `{.compile.}` in `private/zlib_build.nim`. There is no `-lz` and no
  `dynlib` anywhere.
* Every zlib symbol is renamed with the `gzfast_z_` prefix by a patch
  block in `src/vendor/zlib-1.3.2/zconf.h`, generated from the actual
  object symbol tables. The package test inspects built binaries
  (`otool -L` / `ldd` / `nm`) to prove no system zlib is linked and no
  unprefixed zlib symbol is exported.
* Nim never sees `z_stream`. The opaque C shim
  (`src/vendor/gzfast_zlib_shim.[ch]`) exposes: create/destroy/reset,
  `prime`, `set_dictionary`, one `step` inflate call with explicit
  in/out pointer pairs, totals, `data_type`, `crc32`, `crc32_combine`.
  All inflater state is per-handle; there is no global mutable state.
* The vendor tree lives under `src/` because nimble installs `srcDir`
  contents at the package root; this keeps `{.compile.}` paths
  identical in a checkout and in an installed package.

### Gzip framing (`src/gzfast/gzip/`)

* `header.nim`: byte-fed, allocation-free state machine. Validates
  magic, method, reserved flags, FEXTRA subfield structure (detecting
  the BGZF `BC` subfield), FNAME/FCOMMENT termination, and FHCRC
  against an incrementally computed CRC32. Being byte-fed, it is
  immune to headers split across input pages or trickling streams.
* `footer.nim`: 8-byte trailer (CRC32, ISIZE), little-endian.

### Authoritative sequential path (`src/gzfast/paths/sequential.nim`)

The one-thread implementation, the fallback for non-positional
sources, and the correctness oracle for future parallel paths.

* Compressed input flows through one bounded page buffer
  (`inputPageSize`, default 1 MiB); decoded output through one bounded
  chunk buffer (`decodedChunkSize`, default 4 MiB). Nothing is
  proportional to file size.
* Member loop: header → raw inflate → trailer verification
  (CRC32 + ISIZE modulo 2^32) → next header or verified EOF.
  Trailing junk after the final member is rejected.
* `outputLimit` clamps the writable space per inflate step; when the
  limit is reached, a zero-space probe distinguishes "file ends
  exactly at the limit" (success) from "more output pending"
  (`geOutputLimit`). No byte beyond the limit is ever emitted.
* Errors carry the best known compressed-byte offset and member index.
* zlib in raw mode stops exactly at the DEFLATE payload end, so the
  trailer is read from the bytes zlib left unconsumed; no look-behind
  heuristics are needed on this path.

### Public API (`src/gzfast/reader.nim`, `decoder.nim`, `gzfast.nim`)

* `GzFastStream` is a `ref object of StreamObj` with explicit vtable
  implementations: `readData`, `readDataStr`, `atEnd`, `close`, plus
  raising implementations for seek/peek/write (std/streams calls
  vtable procs unconditionally, so nil slots would crash; seeking must
  never silently restart decompression). The `atEnd` look-ahead
  performs reads, which requires an explicit proc-type cast because
  the `atEndImpl` slot is typed `tags: []`.
* `finish()` drains and verifies the remaining stream without
  emitting output; `cancel()` stops unread work; `close()` before EOF
  cancels. All resource cleanup is deterministic and idempotent.
* `decodeTo`/`decompressFile` decode directly to a `File`/`Stream`
  touched only by the caller's thread.
* `openGzFastSequential` decodes from any `Stream` via the sequential
  backend.

### Positional source (`src/gzfast/source.nim`, `private/platform_io.nim`)

* `ReadAtSource` is a non-owning POD view: context pointer, snapshotted
  `uint64` length and a `gcsafe`, `raises: []` callback.
* POSIX performs independent `pread` calls. Windows opens with
  `FILE_FLAG_OVERLAPPED` and supplies a fresh 64-bit `OVERLAPPED`
  offset for each `ReadFile`; fallback targets serialize seek/read with
  a lock. `readExactAt` loops over short reads and reports premature EOF.
* `OwnedReadAtSource` controls handle lifetime. An immutable shared-heap
  memory source supports deterministic tests. Owners must outlive all
  worker views; compressed files must not change after the size snapshot.

### Shared buffers (`src/gzfast/buffers.nim`)

* `SharedBuffer` is an explicitly moved POD handle over `allocShared` /
  `allocShared0`: pointer, logical length, capacity, element width,
  owner state and tracker pointer. It has no destructor; cancellation
  can therefore drain and free every outstanding handle deterministically.
* Ownership transitions are checked (`worker → result queue → coordinator
  → output queue → reader`). The per-runtime `AllocationTracker` uses
  atomics for live bytes, peak bytes, live buffers and total allocations;
  no global decoder state is used.

### Bounded runtime (`src/gzfast/scheduler/`)

* `BoundedQueue[T]` rejects managed message types at compile time and
  stores POD records in a fixed shared-memory ring. One lock plus
  `notEmpty`/`notFull` conditions provides blocking push/pop; close and
  cancellation broadcast to every waiter. Closed queues remain drainable.
* Jobs/results contain only offsets, integers, enums, generation IDs,
  plain error records and `SharedBuffer` handles. Worker exceptions never
  cross a queue.
* The fixed worker pool owns thread lifecycles. Cancellation stops
  admission, closes queues, wakes blocked publishers/consumers, joins all
  workers, then drains result/coordinator buffers.
* `OrderedCoordinator` is a fixed ordinal ring, not an unbounded map. It
  detects stale, duplicate and out-of-window results and emits only the
  next contiguous ordinal. Synthetic tests force out-of-order completion,
  full queues, worker errors, repeated shutdown and concurrent independent
  runtimes, with zero final shared allocations.

### Independent-member parallel paths (`src/gzfast/paths/member_parallel.nim`)

* Valid BGZF `BC`/`BSIZE` links and densely concatenated ordinary gzip
  members are decoded as independent worker jobs. Every member parses
  its own header, resets raw inflate history, verifies CRC32 and ISIZE,
  and publishes a bounded shared output buffer.
* The coordinator accepts a candidate only when its compressed start is
  exactly the verified end of its predecessor. Valid gzip magic inside
  an earlier member is discarded rather than committed.
* Broken BGZF/member chains fall back to the authoritative sequential
  decoder at the first uncommitted member boundary. Reports use `dpBgzf`,
  `dpMultiMember`, or `dpMixed` as appropriate.

### Pure-Nim DEFLATE structures (`src/gzfast/deflate/`)

* `bitreader.nim` reads DEFLATE's LSB-first bit stream from arbitrary
  64-bit positions through bounded positional pages. A 64-bit reservoir
  lets peek refill without advancing; reads are limited to 32 bits and
  expected EOF is an exception-free parse failure.
* `huffman.nim` constructs canonical tables in fixed reusable storage.
  It validates maximum lengths, empty alphabets, Kraft oversubscription,
  invalid incomplete trees and the permitted one-symbol/one-bit shape.
  Decode uses padded tail peeks but advances only when the real available
  bits cover the selected code. Fixed RFC literal/distance trees share
  the same constructor.
* `stored.nim` validates alignment plus `LEN`/`NLEN` and exact payload
  bounds. `dynamic_header.nim` expands `HLIT`/`HDIST`/`HCLEN`, precode
  symbols and repeats 16/17/18 into a fixed 318-entry workspace; it
  requires EOB, rejects reserved distances and supports the legal empty
  distance tree when no length symbols exist.
* `blockfinder.nim` scans one bounded bit range with one paged reader and
  returns only the next structurally valid non-final dynamic header. It
  retains no file-size-proportional candidate index. Returned offsets are
  explicitly non-authoritative until complete marker decode and exact
  predecessor/successor boundary equality in Milestone 8.
* A bundled-zlib `Z_TREES` differential test verifies exact dynamic-header
  end positions. Decoder hot-path symbol lookup allocates nothing;
  dynamic workspaces are intended for one-time allocation per worker.

### Marker decoding and exact handoff (`marker_decode.nim`, `exact_decode.nim`)

* Speculative output uses uint16 symbols: literals `0..255` and markers
  `32768..65535`, where marker `32768 + i` identifies predecessor-window
  position `i` from oldest to newest. Values `256..32767` are never emitted.
* The initial marker window is virtual. Match source index is computed
  against `32768 markers + output so far`; only output is stored. Scalar
  copies append one symbol at a time, so distance-one and all other overlap
  cases naturally see newly appended values and propagate markers exactly.
* Literal, match and stored operations check the complete requested growth
  before mutation. A speculative cap failure never exposes a partial match.
* After each complete non-final block, only the active final 32 KiB is
  inspected. If it contains literals only, it is exported oldest-to-newest
  as an exact dictionary; markers earlier than that window do not block
  handoff.
* Exact continuation resets a private raw inflater, primes the unread bits
  from an unaligned containing byte, advances input to the following byte,
  and supplies the marker-free dictionary with `inflateSetDictionary`.
  `Z_BLOCK` boundaries are reconstructed as `absolute consumed bytes * 8 -
  (data_type & 0x3f)`; final boundaries are byte-aligned even when zlib
  returns `Z_OK` rather than `Z_STREAM_END`.
* Tests compare scalar marker matches with a naive resolved-history oracle
  across distances 1..32768, prefix lengths around the window boundary,
  and match lengths through 258. An unaligned dictionary-dependent handoff
  produces byte-identical output to full authoritative raw inflate without
  decoding the successful native prefix twice.

### Ordinary-gzip marker path (`marker_resolve.nim`, `paths/marker.nim`)

* Candidate discovery is rolling and bounded. Each batch retains one
  sentinel dynamic boundary for the following batch rather than building
  a whole-file index. Decode jobs use even ordinals; the corresponding
  full replacement jobs use the immediately following odd ordinal, so the
  ordered coordinator cannot advance to the next speculative decode until
  the current output is fully resolved.
* Suffix-only `windowAfter` resolution computes the dependency window
  against the current authoritative predecessor. Full scalar replacement
  runs as `jkResolveMarkers` worker work and produces a separately tracked
  byte buffer for ordered delivery.
* A result commits only when `result.startBit == authoritativeBit` and its
  exact end equals the next candidate start. Valid dynamic headers inside
  stored/compressed payload therefore remain harmless: mismatch cancels
  dependent work and bridges from the last committed bit/window.
* Marker-free boundaries continue through raw zlib with exact priming and
  dictionary injection. If an exact tail exceeds its bounded allowance or
  any speculative chain fails, the permanent correctness oracle replays
  the member from its real gzip header, discards the already committed
  decoded prefix, and exposes only the unread suffix. This uses bounded
  buffers and never duplicates bytes to the consumer.
* Resolved chunks update member CRC32 and decoded size before admission to
  output. BFINAL aligns to the byte footer, which must match CRC32 and
  modulo-2^32 ISIZE. Later concatenated members may transition to the
  sequential backend, producing a `dpMixed` report.
* Public reads, direct output and early `finish()` can use this route after
  BGZF and dense-member selection only when `enableMarkerPath` (or the CLI
  `--marker-path` flag) is set. It is opt-in because current measured
  ordinary-FASTQ workloads are still faster through sequential zlib.
  `threads = 1` remains the authoritative sequential path. Output and
  failures are deterministic across tested worker counts.
* Even when explicitly enabled, the marker path engages only when
  speculation can pay: the member must span at least two compressed grids,
  and an open-time probe of the first batch must find at least one
  speculative candidate beyond the authoritative position. Otherwise
  opening falls through to the sequential zlib path before any worker is
  spawned. Worker creation is capped at the probed first-batch parallelism,
  and the probed candidates are reused by the first batch instead of being
  searched twice.

### Robustness gates (`tests/corruption`, `tests/concurrency`, `fuzz`)

* Mutation tests enforce an invalid-success invariant: every changed input
  either raises a typed decoder error or reproduces the exact original bytes
  and completes footer verification. The matrix covers all single-bit
  positions of a compact member, all truncation points, footer bytes,
  dynamic payload bits, later members, trailing data and BGZF links.
* Parallel error records remain speculative until their compressed start is
  the ordered authoritative member boundary. The coordinator assigns public
  zero-based member indices from committed member count, not candidate/job
  ordinals.
* Public stress tests run independent decoder pools concurrently, consume
  one byte at a time with delays, repeatedly stop after one byte, decode
  1,000-member streams, reach output limits with outstanding work and force
  low-memory fallback. Concurrency executables run under parent-enforced
  deadlines so a deadlock fails instead of stalling CI.
* Large fixtures are generated as highly compressed fixed-DEFLATE streams;
  decoded output is never materialized by the test. Incremental CRC and byte
  counts validate 16/32 MiB streams through a 4097-byte destination while
  reported peak buffering stays below the configured ceiling and does not
  scale with logical file size.
* Standalone header and bounded whole-decoder fuzz harnesses accept process-
  based fuzzer inputs without system compression libraries. Linux CI runs
  separate ASan/UBSan jobs and corpus fuzz smoke; scheduled jobs add Valgrind
  and informational ThreadSanitizer coverage.

### Profile-driven performance (`benchmarks/`, optimized scalar kernels)

* Release benchmarks generate verified ordinary-marker, fallback, repeated
  BGZF and many-member corpora. Every row asserts footer verification,
  decoded byte count and CRC, and reports path, wall/CPU time, throughput,
  peak workers and accounted buffering. Detailed local results and hardware
  are recorded in `benchmarks/PROFILE.md`.
* Marker matches reserve once, materialize predecessor markers directly,
  copy one non-overlapping period and geometrically double overlap. Count,
  marker telemetry and logical length update per run/match rather than per
  symbol. The original scalar routine remains a differential oracle.
* Marker storage starts at at most 64 Ki symbols and grows geometrically under
  the unchanged hard cap, avoiding eager 32 MiB allocations at the default
  speculative limit. Large full-window replacement uses a 65,536-byte lookup
  table; smaller/partial windows use a checked direct-pointer scalar loop.
* Marker source, queues, workers, workspaces and coordinator persist across
  rolling batches with monotonic ordinals. Verify-only paths release already
  authenticated buffers without copying to scratch.
* Up to eight exact adjacent BGZF blocks share one worker job/result buffer.
  Each block is still parsed, reset, inflated and authenticated independently;
  a grouped error keeps group-start authority and exact failing-block metadata.
* Automatic budgets above four use `ceil(2 * sqrt(maximum))`; explicit budgets
  remain explicit. Extremely dense sub-256-byte ordinary members select the
  faster sequential oracle until safe ordinary-member grouping exists.
* Architecture-specific SIMD is intentionally absent. The measured LUT path
  addresses large replacement buffers, upstream AVX2 regressed on irregular
  marker loads, and current profiles place remaining cost in native decode and
  scheduling. Runtime SSE/NEON kernels remain optional future experiments.

## Further performance work

Generation-tagged empirical worker growth/retirement, ordinary tiny-member
grouping, backend-specific zero-copy sink draining and native-hardware FASTQ
benchmarks remain measured follow-ups rather than correctness requirements.

* `deflate/` + `paths/marker.nim`: rapidgzip-style speculative
  decoding with uint16 marker symbols for unknown predecessor windows,
  exact boundary validation, marker resolution, and sequential
  bridging from the last authoritative boundary.

Memory stays proportional to `workers × per-worker buffers + bounded
in-flight output`, never to file size. Cancellation is an atomic flag
observed by every blocking component; shutdown joins every thread and
drains every buffer.

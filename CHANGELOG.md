# Changelog

All notable changes to this project are documented here. The format
follows common changelog conventions; versions follow SemVer.

## [0.2.0] 

### Added

* Generic streaming gzip output through `GzFastWriter`, with path and
  borrowed/owned `File` constructors, configurable compression level,
  strategy and output-buffer size.
* Allocation-conscious `writeData(pointer, len)` for callers that batch
  records into reusable buffers, plus `writeString`, `writeBytes`, and
  `writeLine` convenience procedures.
* `GzipWriteReport` with compressed and uncompressed byte counts, CRC32,
  and gzip ISIZE. `finish()` returns the report; `close()` is sufficient
  for simple usage and finishes the gzip member automatically.
* Raw DEFLATE support in the private vendored-zlib shim. Writer builds use
  the bundled, symbol-prefixed zlib and add no system-zlib runtime
  dependency.
* CLI compression for file and standard-input workflows:
  `gzfast -c input > input.gz`, `gzfast -c -o input.gz input`, and
  `cat input | gzfast -c > input.gz`. Existing `-dc` and `--stdout`
  decompression behavior is preserved.
* Deterministic writer benchmark harness covering generic text,
  pseudo-random data, and FASTQ-shaped data at levels 1, 6, and 9, with
  `gzip` and `pigz -p1` baselines, verified output, raw CSV, and summary
  reporting.
* `AGENT_DOCUMENTATION.md` with public API examples, architecture rules,
  validation commands, and benchmark guidance for coding agents.

### Changed

* Package and CLI version advanced to `0.2.0`; project descriptions now
  describe verified gzip I/O rather than decompression alone.
* CLI `-c` now selects compression. The established `-dc` combination
  remains decompression to standard output; `--stdout` is the explicit
  long-form output selector.
* README and benchmark documentation now cover streaming writes, CLI
  compression, writer performance methodology, and 0.2.0 release status.

### Fixed

* Writer finalization now checks the C `fflush()` result directly, so
  delayed disk-full and other buffered output failures are reported.
* Writer lifecycle behavior is covered for repeated `finish()`/`close()`,
  writes after finish or close, invalid paths, nil outputs, and failed
  finalization. A failed writer remains poisoned while `close()` still
  releases resources and remains idempotent.
* Gzip trailer ISIZE accounting is explicitly calculated and tested modulo
  2^32, including values beyond the 4 GiB boundary.
* CLI compression refuses accidental in-place output, including aliases of
  the same physical file, and preserves existing files unless `-f` is used.

## [0.1.0] - alpha candidate

### Fixed

* Plain `nimble build` now uses the repository `nim.cfg` default profile:
  ORC, threads enabled, `-d:release`, and `--opt:speed`.
* Ordinary single-member gzip no longer enters the marker/window path by
  default when `threads > 1`. That path remains available via
  `GzFastConfig.enableMarkerPath` or CLI `--marker-path`; BGZF and dense
  concatenated-member parallelism remain enabled by default.
* CLI `--stats` now reports selected decode paths, peak workers, wall/CPU
  time and decoded throughput.
* Added `benchmarks/bench_fastq.nim` and `nimble benchFastq` for CSV
  benchmark runs over real FASTQ.gz files, including default gzfast,
  marker-path opt-in variants and an optional `gunzip` wall-time baseline.
  The harness can also summarize captured CSVs with
  `bench_fastq --summary RESULTS.csv`, reporting aggregate timing/resource
  columns and per-dataset speedup/marker ratios.
* `bench_fastq` now adds optional `pigz` wall-time baselines
  (`pigz -dc -p N`) for each configured thread budget when `pigz` is
  available on `PATH`; use `--no-pigz` to disable them. Summary CSVs now
  include explicit speedups versus `pigz -p1`, same-thread `pigz`, and the
  best `pigz` row for each dataset.
* `bench_fastq` now records coarse workload classes and output modes so
  real-file benchmarks cover ordinary FASTQ.gz, BGZF/concatenated gzip,
  generic gzip inputs, in-process API reads, CLI stdout-to-null, temporary
  file output and `wc -c` pipe consumption without making FASTQ-specific
  assumptions inside the harness.
* The benchmark workflow now separates practical, exhaustive and I/O-focused
  runs: `make bench` uses the cheaper `api,cli-null` matrix with marker
  variants disabled, `make bench-exhaustive` restores the full
  API/CLI/file/pipe plus marker matrix, and `make bench-io` isolates file
  output and pipe-consumer overhead.
* `generate_corpus.nim` now creates FASTQ-shaped single-member,
  concatenated-member and BGZF gzip controls plus generic line-oriented text
  and stored-block pseudo-random gzip controls, so optimization can target
  FASTQ workloads without overfitting to ordinary single-member FASTQ.gz.
* File output now drains the sequential backend directly from its internal
  decode buffer, avoiding one caller-buffer copy on the default ordinary
  gzip path.
* Sanitizer test tasks now pass `-fno-omit-frame-pointer` through
  `--passC`, fixing Linux Nim command-line parsing under Nim 2.2.10.
  UBSan now disables only the noisy Nim-generated `null` `_Bool`
  diagnostics and treats remaining undefined-behavior checks as fatal.
* Release hygiene now ignores generated binaries/CSVs/caches and makes
  `make clean` preserve committed gzip corpus fixtures and local benchmark
  inputs.
* Marker path no longer engages when speculation cannot overlap: members
  smaller than two compressed grids, or whose first batch has no
  speculative candidate beyond the authoritative position, now decode
  through the faster sequential zlib path. Worker pools are only spawned
  after that probe succeeds and are capped at the probed first-batch
  parallelism, removing idle-thread overhead and inverse thread scaling
  on small inputs.
* CLI short options with separate values (`-t 1`, `-o file`) are now
  parsed correctly; previously only the attached forms (`-t1`, `-t=1`)
  and the long forms (`--threads 1`) worked.

### Added (milestones 0???10)

* Project skeleton: Nimble package, directory layout, licenses,
  upstream notices, CI skeleton, examples.
* Vendored zlib 1.3.2 compiled via `{.compile.}` with `gzfast_z_*`
  symbol prefixing verified by binary inspection; opaque C shim;
  private Nim bindings. No system zlib required.
* Authoritative sequential gzip decoder: full header validation
  (FEXTRA/FNAME/FCOMMENT/FHCRC, reserved flags, BGZF `BC` detection),
  raw-DEFLATE streaming through bounded buffers, per-member CRC32 and
  ISIZE verification, concatenated members, trailing-junk rejection,
  typed errors with compressed offsets, output-limit guard.
* Public API: `GzFastConfig`, `GzFastDecoder`, `GzFastStream`
  (forward-only `std/streams` reader), `openGzFast`,
  `openGzFastSequential`, `decodeTo`, `decompressFile`, `finish`,
  `cancel`, `stats`, `DecodeReport`, `GzFastError`.
* `gzfast` CLI: `-d/-c/-o/-t/--memory/--output-limit/--verify/
  --stats/--quiet/-f/--version/--help`, documented exit codes.
* Test suite: unit (shim, header, footer, sequential), integration
  (public API, CLI), committed binary corpus with manifest, corruption
  matrix over small fixtures, package-install validation.
* Positional `ReadAtSource`: POSIX `pread`, Windows
  `ReadFile`/`OVERLAPPED`, fallback locked seek/read, snapshotted
  64-bit lengths, exact short-read handling, and immutable test source.
* Explicit `SharedBuffer` ownership over `allocShared`, with per-runtime
  atomic live/peak byte and allocation counters.
* Fixed-capacity POD queues with one lock, `notEmpty`/`notFull`
  conditions, cancellation-aware blocking, close and drain semantics.
* Fixed worker pool, plain job/error/result records, bounded ordinal-ring
  coordinator, deterministic cancellation/join, and synthetic runtime
  tests for out-of-order completion, full queues and independent pools.
* Parallel BGZF and dense concatenated-member paths with independent
  CRC32/ISIZE verification, ordered streaming output and sequential
  fallback from the first uncommitted verified member boundary.
* Pure-Nim DEFLATE structures: 64-bit positional LSB-first bit reader,
  reusable canonical Huffman tables, fixed trees, stored-block
  validation, dynamic-header expansion, common block headers and a
  bounded non-final dynamic-block candidate finder.
* Differential dynamic-header boundary validation against bundled
  zlib's `Z_TREES`, plus exhaustive alignment, truncation, tree-shape,
  repeat-code, reserved-distance and search-range tests.
* Scalar uint16 marker decoder over a virtual unknown 32 KiB predecessor
  window. Stored, fixed and dynamic blocks share the pure-Nim DEFLATE
  tables; LZ77 matches preserve overlap and marker propagation with a
  hard all-or-nothing speculative output cap.
* Marker-free final-window detection at complete block boundaries and
  exact raw-zlib continuation using `inflatePrime`, oldest-to-newest
  dictionaries, `Z_BLOCK`, and low-six-bit `data_type` position recovery.
* Differential marker-copy tests against a naive known-window oracle and
  exact handoff tests for unaligned, dictionary-dependent continuation,
  stored boundaries, and output-free final blocks.
* Scalar full marker replacement and suffix-only next-window resolution,
  including newest-aligned partial predecessor windows.
* Rolling bounded ordinary-gzip marker scheduling with dynamic-header
  candidates, exact predecessor/successor bit adjacency, interleaved
  decode/resolution worker ordinals, ordered resolved output, CRC32/ISIZE
  footer authentication, marker-free exact continuation, and bounded
  authoritative replay fallback from the real member header.
* Public marker-path tests across worker counts, false candidates inside
  stored payload, forced boundary mismatch, terminal corruption, early
  close, `finish()` before EOF, and global output limits.
* Systematic corruption hardening: every single-bit mutation of a compact
  member, every-byte truncation, every footer byte, selected dynamic bits,
  late-member corruption metadata, trailing junk, and BGZF link/footer
  mutations must fail or reproduce the exact authenticated output.
* Public stress gates for concurrent decoder instances, delayed one-byte
  consumers, repeated early close across backends, thousands of tiny/empty
  members, outstanding-job output limits, and low-memory fallback.
* Generated 16/32 MiB logical streams consumed through 4097-byte buffers,
  with incremental CRC, footer/report checks and stable peak-memory bounds.
* Cross-platform child-process deadlines for concurrency executables.
* Standalone bounded header/decode fuzz harnesses, corpus smoke task,
  expanded ASan/UBSan tasks, and scheduled Valgrind/informational TSan CI.
* Deterministic generated release benchmarks for successful marker work,
  intentional marker fallback, repeated BGZF and 10,000 tiny members, with
  path/CRC assertions and CSV timing/worker/memory output.
* Profile-driven marker optimizations: geometric overlap-correct LZ77 bulk
  copying, lazy bounded marker growth, direct-pointer replacement, large
  complete-window lookup tables, bulk rolling-window copies, one-probe block
  finding and persistent marker worker runtimes.
* Up-to-eight-block BGZF grouping with one aggregate result allocation while
  preserving independent reset, BSIZE, CRC32 and ISIZE verification.
* Conservative automatic square-root worker bootstrap, useful-work capping,
  tiny-member sequential admission, copy-free verify drains and dedicated
  file output without `FileStream` dispatch.
* Measured profile report and explicit decision not to add unproven SIMD;
  scalar differential oracles remain available on every platform.

# NIM Library: `gzfast`

## 1. Mission

Implement **`gzfast`**, a modern Nim library and command-line utility for fast, verified, multithreaded decompression of gzip files.

The primary use case is streaming very large `FASTQ.gz` files through bioinformatics pipelines:

```bash
gzfast -dc --threads 8 reads.fastq.gz | downstream-tool
```

and from Nim:

```nim
import gzfast
import std/streams

let decoder = initGzFastDecoder(threads = 8)
let reader = decoder.open("reads.fastq.gz")
defer:
  reader.close()

var buffer = newString(1024 * 1024)

while true:
  let n = reader.readData(addr buffer[0], buffer.len)
  if n == 0:
    break

  processData(addr buffer[0], n)

let report = reader.finish()
echo report
```

The library must stream output incrementally. It must never decompress the complete input into memory.

---

# 2. Non-negotiable requirements

## 2.1 Installation and dependencies

A user must be able to install and compile with:

```bash
nimble install gzfast
nim c -d:release --threads:on program.nim
```

The resulting program must not require:

* a system installation of zlib;
* `libz.so`;
* `zlib1.dll`;
* zlib development headers;
* `pkg-config`;
* CMake;
* Cargo or Rust;
* NASM;
* another non-Nim compression library.

External pure-Nim dependencies are permitted, but the initial implementation should preferably use only the Nim standard library.

Bundle the necessary C sources inside the Nimble package and compile them through Nim’s `{.compile.}` mechanism. Nim explicitly supports compiling bundled C sources as part of the application build.

## 2.2 Streaming and memory

The implementation must:

* emit decompressed bytes incrementally;
* use bounded input, output and speculative buffers;
* apply backpressure when the consumer is slow;
* support files much larger than available RAM;
* never call `readAll` on the compressed or decompressed file;
* never build an in-memory representation proportional to file size;
* expose an output-limit option to protect applications from decompression bombs.

Memory use should be approximately proportional to:

```text
active workers
× per-worker input/scratch allocation
+ bounded in-flight output
+ bounded marker-resolution work
```

not to compressed or decompressed file size.

## 2.3 Correctness

The library must strictly validate:

* gzip headers;
* optional gzip fields;
* DEFLATE syntax;
* final-block termination;
* member footer CRC32;
* member footer ISIZE;
* every member of concatenated gzip;
* every block/member in BGZF.

A successful EOF or successful `finish()` must mean the entire compressed stream was validated.

## 2.4 Parallelism

`gzfast` must eventually parallelise ordinary gzip files, not only BGZF or concatenated gzip.

The complete implementation should support:

1. sequential authoritative decompression;
2. BGZF member parallelism;
3. concatenated gzip member parallelism;
4. stored-block parallelism where applicable;
5. rapidgzip-style marker/window parallel decompression of ordinary gzip streams.

The Rust implementation already narrows the scope appropriately: it performs verified parallel gzip decompression without encoding, persistent indexes or decoded-output seeking. Its architecture uses bounded parallel paths and one ordered coordinator. Use this as the primary structural reference.

## 2.5 Random access is out of scope

Do not implement:

* seeking in decompressed output;
* index creation or persistence;
* `.gzi` or rapidgzip index files;
* LRU caches for seeking;
* random reads from the decompressed address space;
* prefetching designed for future seeks.

Internal positional reading of the **compressed** file is allowed and required for parallel operation. This is an implementation detail and is not user-visible random access.

## 2.6 Portability

Primary supported platforms:

* Linux x86-64;
* Linux AArch64;
* macOS Apple Silicon;
* macOS x86-64;
* Windows x86-64.

Support files larger than 2 GiB on every platform. Use 64-bit offsets throughout.

The initial release may officially support only native C/C++ backends. Reject the JavaScript backend at compile time.

---

# 3. Technical baseline

Target modern stable Nim:

```nim
requires "nim >= 2.2.0"
```

CI must test the current stable Nim 2.2 patch release and Nim devel. At the time of planning, the current stable documentation is for Nim 2.2.10. ORC is the default and recommended memory manager for newly written Nim code.

Standard production compilation:

```bash
nim c \
  -d:release \
  --threads:on \
  --mm:orc \
  src/gzfast_cli.nim
```

Do not use `-d:danger` for release testing. It may be used only in explicitly labelled benchmarks.

Use:

* `std/typedthreads`;
* `std/locks`;
* `std/atomics`;
* `std/options`;
* `std/streams`;
* `std/os`;
* platform APIs for positional file reads.

Nim threads require `--threads:on`. Modern Nim permits ORC-managed data to be used across threads under documented lifetime constraints, but large hot-path buffers should still use explicit ownership and shared allocation rather than relying on atomic reference counting.

---

# 4. Upstream reference versions

Pin the design work to specific upstream revisions rather than following moving branches.

Use:

```text
mxmlnkn/rapidgzip
Commit: d2350e9c9ba54398cd64e45bfc8c631beec017f0

COMBINE-lab/rapidgzip-rust
Commit: 72511b7b14999421a29b1449406972faa7e62137

zlib
Version: 1.3.2
```

Record these in:

```text
UPSTREAM.md
THIRD_PARTY_NOTICES.md
```

The Rust architecture specifically identifies these rapidgzip components as the principal marker/window references:

```text
blockfinder/DynamicHuffman.hpp
chunkdecoding/GzipChunk.hpp
DecodedData.hpp
MarkerReplacement.hpp
```

Do not copy code without attribution. Preserve applicable MIT, Apache-2.0 and BSD-3-Clause notices for translated or derived portions.

Bundle zlib 1.3.2 under its permissive zlib licence and retain its licence notice.

---

# 5. Repository structure

Create the repository with the following approximate layout:

```text
gzfast/
├── gzfast.nimble
├── README.md
├── CHANGELOG.md
├── LICENSE
├── UPSTREAM.md
├── THIRD_PARTY_NOTICES.md
├── ARCHITECTURE.md
├── CONTRIBUTING.md
├── SECURITY.md
├── src/
│   ├── gzfast.nim
│   ├── gzfast_cli.nim
│   └── gzfast/
│       ├── config.nim
│       ├── decoder.nim
│       ├── reader.nim
│       ├── errors.nim
│       ├── report.nim
│       ├── stats.nim
│       ├── source.nim
│       ├── buffers.nim
│       ├── gzip/
│       │   ├── header.nim
│       │   ├── footer.nim
│       │   ├── members.nim
│       │   └── bgzf.nim
│       ├── deflate/
│       │   ├── bitreader.nim
│       │   ├── constants.nim
│       │   ├── huffman.nim
│       │   ├── dynamic_header.nim
│       │   ├── blockfinder.nim
│       │   ├── marker_decode.nim
│       │   ├── marker_resolve.nim
│       │   └── exact_decode.nim
│       ├── scheduler/
│       │   ├── bounded_queue.nim
│       │   ├── jobs.nim
│       │   ├── workers.nim
│       │   ├── coordinator.nim
│       │   └── controller.nim
│       ├── paths/
│       │   ├── sequential.nim
│       │   ├── stored.nim
│       │   ├── bgzf.nim
│       │   ├── multimember.nim
│       │   └── marker.nim
│       └── private/
│           ├── zlib_build.nim
│           ├── zlib_api.nim
│           └── platform_io.nim
├── vendor/
│   ├── zlib-1.3.2/
│   ├── gzfast_zlib_shim.c
│   ├── gzfast_zlib_shim.h
│   └── README.md
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── concurrency/
│   ├── corpus/
│   ├── corruption/
│   ├── package/
│   └── helpers/
├── fuzz/
│   ├── fuzz_decode.nim
│   ├── fuzz_header.nim
│   └── README.md
├── benchmarks/
│   ├── bench_decode.nim
│   ├── generate_corpus.nim
│   ├── datasets.md
│   └── run_benchmarks.nims
├── examples/
│   ├── stream_fastq.nim
│   ├── decompress_file.nim
│   ├── verify_only.nim
│   └── custom_limits.nim
└── .github/
    └── workflows/
```

Only `src/gzfast.nim` should define the normal public import surface. Keep internal modules private unless there is a strong public use case.

---

# 6. Public API

The API should feel like a normal Nim streaming library rather than a wrapper around a command-line program.

## 6.1 Configuration

Define:

```nim
type
  GzFastConfig* = object
    ## Maximum decoder-worker budget.
    ## Zero means automatic.
    threads*: int

    ## Target decoded output chunk size.
    decodedChunkSize*: int

    ## Approximate spacing between speculative starts.
    compressedGridSize*: int

    ## Positional input page size.
    inputPageSize*: int

    ## Maximum number of completed chunks awaiting consumption.
    ## Zero means derive from the active worker budget.
    inFlightChunks*: int

    ## Maximum decoded bytes produced speculatively by one job.
    maxSpeculativeOutput*: int

    ## Optional total decoded-output limit.
    outputLimit*: Option[uint64]

    ## Optional approximate internal memory ceiling.
    ## Zero means derive a conservative bound from the worker budget.
    memoryLimit*: int64

    ## Permit a correct sequential fallback when parallel decoding cannot
    ## safely continue.
    allowSequentialFallback*: bool

    ## Maximum accepted combined size of optional gzip header fields.
    maxHeaderSize*: int
```

Provide:

```nim
proc defaultGzFastConfig*(): GzFastConfig

proc validate*(config: GzFastConfig)
  ## Raises GzFastConfigError on invalid values.

proc initGzFastDecoder*(): GzFastDecoder

proc initGzFastDecoder*(config: GzFastConfig): GzFastDecoder

proc initGzFastDecoder*(threads: int): GzFastDecoder
```

Suggested initial defaults:

```text
threads                 0: automatic
decodedChunkSize        4 MiB
compressedGridSize      1 MiB
inputPageSize           1 MiB
inFlightChunks          automatic
maxSpeculativeOutput    16 MiB
outputLimit             none
memoryLimit             automatic
allowSequentialFallback true
maxHeaderSize           1 MiB
```

Treat `threads` as a maximum budget, not necessarily an instruction to allocate every worker immediately.

## 6.2 Streaming reader

Define:

```nim
type
  GzFastStream* = ref object of StreamObj
```

Public construction:

```nim
proc open*(decoder: GzFastDecoder; path: string): GzFastStream

proc openGzFast*(
  path: string;
  threads = 0;
  memoryLimit: int64 = 0
): GzFastStream
```

`GzFastStream` must implement at least:

* `readDataImpl`;
* `atEndImpl`;
* `closeImpl`.

It must be forward-only. Seeking operations must be unsupported and must not silently restart decompression.

Expose:

```nim
proc finish*(reader: GzFastStream): DecodeReport
  ## If EOF has already been reached, return the completed report.
  ##
  ## If called before EOF, discard subsequent decoded output while continuing
  ## to decode and verify the complete compressed stream.

proc cancel*(reader: GzFastStream)
  ## Stop unread work and release resources.

proc stats*(reader: GzFastStream): DecoderStats
  ## Return an approximate lock-free snapshot.
```

Semantics:

* Reading to EOF verifies the complete input.
* `finish()` verifies the complete input.
* `close()` before EOF cancels remaining work.
* Calling `close()` must never leave worker threads running.
* Dropping a reader after an error must cleanly join all threads.
* The stream need not support concurrent calls from multiple consumer threads.
* It may be moved between threads when no call is in progress.

## 6.3 Direct-output API

Provide a lower-overhead API that does not require an intermediate reader queue:

```nim
proc decodeTo*(
  decoder: GzFastDecoder;
  inputPath: string;
  output: File
): DecodeReport

proc decodeTo*(
  decoder: GzFastDecoder;
  inputPath: string;
  output: Stream
): DecodeReport

proc decompressFile*(
  inputPath: string;
  outputPath: string;
  config = defaultGzFastConfig()
): DecodeReport
```

In direct-output mode:

* the caller’s thread acts as the ordered output coordinator;
* worker threads never call the user’s `File` or `Stream`;
* the output object therefore does not need to be thread-safe.

## 6.4 Sequential input streams

Add a separate API for a non-positional compressed source:

```nim
proc openGzFastSequential*(
  input: Stream;
  config = defaultGzFastConfig()
): GzFastStream
```

A pipe, socket or ordinary sequential `Stream` cannot expose arbitrary compressed offsets to workers. It must therefore use the authoritative sequential backend unless explicitly spooled to a temporary file.

Do not silently create temporary files in the initial implementation.

## 6.5 Reporting

Define:

```nim
type
  DecodePath* = enum
    dpSequential
    dpStoredBlocks
    dpBgzf
    dpMultiMember
    dpMarkerWindow
    dpMixed

  DecodeReport* = object
    compressedBytes*: uint64
    decompressedBytes*: uint64
    memberCount*: uint64
    pathsUsed*: set[DecodePath]
    crcVerified*: bool
    peakWorkers*: int
    peakBufferedBytes*: uint64
```

Do not include nondeterministic timing values in equality-sensitive report fields. CLI timing can be reported separately.

## 6.6 Errors

Use a small, stable public error model:

```nim
type
  GzFastErrorKind* = enum
    geInputIo
    geOutputIo
    geInvalidHeader
    geInvalidDeflate
    geTruncatedInput
    geChecksumMismatch
    geSizeMismatch
    geOutputLimit
    geCancelled
    geInternal

  GzFastError* = object of IOError
    kind*: GzFastErrorKind
    compressedOffset*: uint64
    memberIndex*: uint64

  GzFastConfigError* = object of ValueError
```

Every parsing error should report the best known compressed-byte or compressed-bit offset.

Do not pass Nim exception objects through worker queues. Workers must convert failures into plain error records. The coordinator constructs and raises the public exception on the consuming thread.

---

# 7. Core architecture

Use four logical layers:

```text
Compressed source
        │
        ▼
Framing and path selection
        │
        ▼
Bounded parallel worker tasks
        │
        ▼
Ordered coordinator
        │
        ▼
File / Stream / bounded reader queue
```

## 7.1 Source layer

Implement an internal positional source abstraction:

```nim
type
  ReadAtSource = object
    context: pointer
    size: uint64
    readAtProc: proc (
      context: pointer;
      offset: uint64;
      destination: pointer;
      length: int
    ): int {.nimcall, gcsafe, raises: [].}
```

Provide implementations for:

* path-owned file;
* optionally caller-owned file handle;
* in-memory immutable byte buffer for tests.

Platform implementations:

* POSIX: `pread`;
* Windows: `ReadFile` with `OVERLAPPED`;
* fallback platforms: lock, seek and read through one shared file handle.

The source length must be snapshotted before decoding. Document that the compressed file must not be modified during decoding.

Use `uint64` for:

* byte offsets;
* bit offsets;
* compressed sizes;
* decompressed totals.

Use checked conversion before calling APIs that take `int`, `uint32` or zlib’s `uInt`.

## 7.2 Path selection

Select the safest specialised path available:

1. authoritative sequential path;
2. entirely stored-block path;
3. consistent BGZF path;
4. densely spaced ordinary gzip members;
5. marker/window path for ordinary gzip;
6. sequential fallback from the last authoritative boundary.

Never accept a guessed member or block boundary merely because its magic bytes look plausible.

## 7.3 Ordered coordinator

Only the coordinator may:

* commit chunks to output;
* advance the authoritative compressed position;
* advance per-member accounting;
* combine chunk CRCs;
* verify footers;
* announce a member transition;
* expose decoded bytes to the consumer.

Workers may produce results out of order. Results must include an ordinal and compressed start/end positions.

The coordinator keeps a bounded reorder structure keyed by ordinal. Do not let the map grow with file size.

---

# 8. Bundled zlib backend

## 8.1 Purpose

Use bundled zlib only for:

* authoritative sequential raw DEFLATE decoding;
* exact decoding after a valid dictionary becomes known;
* fallback after rejected speculative boundaries;
* `inflatePrime`;
* `inflateSetDictionary`;
* `inflateReset`;
* `Z_BLOCK` decoding;
* CRC32;
* CRC32 combination.

The rapidgzip-specific block finder, marker decoder, scheduler and coordinator should be Nim code.

## 8.2 Vendoring

Vendor an exact copy of zlib 1.3.2.

Include only the production sources needed for inflation and checksums, likely including:

```text
adler32.c
crc32.c
inffast.c
inflate.c
inftrees.c
zutil.c
```

Confirm the exact source set by compiling and testing rather than guessing.

Do not run zlib’s configuration scripts during `nimble install`.

Commit any generated or patched configuration header required by the build.

## 8.3 Symbol isolation

The bundled zlib must not expose normal global symbols such as:

```text
inflate
inflateReset
crc32
zlibVersion
```

Patch or generate the zlib name-mapping section so every symbol receives a project-specific prefix such as:

```text
gzfast_z_inflate
gzfast_z_inflateReset
gzfast_z_crc32
```

Mark the local modification clearly in `vendor/README.md`.

Use hidden symbol visibility where supported, but do not depend on visibility alone to prevent duplicate-symbol conflicts.

## 8.4 C shim

Do not reproduce `z_stream` layout in Nim.

Create a stable opaque wrapper:

```c
typedef struct gzfast_inflater gzfast_inflater;

gzfast_inflater* gzfast_inflater_create(void);
void gzfast_inflater_destroy(gzfast_inflater* state);
int gzfast_inflater_reset(gzfast_inflater* state);

int gzfast_inflater_prime(
    gzfast_inflater* state,
    unsigned bit_count,
    unsigned bit_value
);

int gzfast_inflater_set_dictionary(
    gzfast_inflater* state,
    const unsigned char* data,
    size_t length
);

int gzfast_inflater_step(
    gzfast_inflater* state,
    const unsigned char** input,
    size_t* input_length,
    unsigned char** output,
    size_t* output_length,
    int flush_mode
);

uint64_t gzfast_inflater_total_in(
    const gzfast_inflater* state
);

uint64_t gzfast_inflater_total_out(
    const gzfast_inflater* state
);

int gzfast_inflater_data_type(
    const gzfast_inflater* state
);

uint32_t gzfast_crc32(
    uint32_t previous,
    const unsigned char* data,
    size_t length
);

uint32_t gzfast_crc32_combine(
    uint32_t first,
    uint32_t second,
    uint64_t second_length
);
```

The shim must:

* initialise raw DEFLATE mode;
* avoid exposing zlib macros to Nim;
* return integer error codes rather than C strings;
* have no global mutable inflater state;
* be reusable by one worker across many jobs;
* compile on GCC, Clang and MSVC-compatible toolchains.

## 8.5 Nim build integration

Create one private Nim module containing all `{.compile.}` declarations.

There must be no:

```nim
{.passL: "-lz".}
```

and no zlib `dynlib` declaration.

Add package tests that install `gzfast` from a generated Nimble archive into a clean temporary Nimble directory, compile an example, and inspect the resulting binary for unwanted zlib dependencies.

---

# 9. Threading and ownership model

## 9.1 Worker pool

Implement a library-owned worker pool using `std/typedthreads`.

Avoid a third-party task framework initially because:

* the scheduler needs precise bounded-memory behaviour;
* marker-resolution jobs have different priority from decode jobs;
* large buffer ownership must be explicit;
* cancellation and output backpressure are central to correctness.

Each worker owns:

* one zlib inflater;
* one positional input page;
* reusable Huffman tables;
* local bit-reader state;
* reusable small scratch buffers.

Workers must not share their inflater state.

## 9.2 Job types

Use a tagged POD object:

```nim
type
  JobKind = enum
    jkDecodeBoundary
    jkResolveMarkers
    jkDecodeBgzfGroup
    jkDecodeMember
    jkDecodeStoredRange
    jkShutdown
```

Job records should contain only:

* integers;
* enums;
* plain offsets;
* pointers to explicitly owned shared buffers;
* generation and cancellation identifiers.

Do not put `string`, `seq`, `ref`, closures or exceptions directly into a hot worker queue.

## 9.3 Bounded queues

Implement a fixed-capacity queue with:

* a ring buffer;
* one `Lock`;
* `notEmpty` and `notFull` condition variables;
* cancellation-aware blocking;
* explicit close semantics.

Create separate queues where useful:

```text
decode jobs
marker-resolution jobs
completed results
reader output
```

Workers should take marker-resolution work before speculative decode work because resolving a predecessor window may unblock several later chunks.

Do not use unbounded channels.

## 9.4 Shared buffers

Implement a private `SharedBuffer` abstraction over:

```nim
allocShared
allocShared0
deallocShared
```

Track:

* pointer;
* length;
* capacity;
* element width;
* ownership state;
* optional allocation counter for tests.

Large buffers must have one clear owner at all times.

Ownership transitions:

```text
worker
  → result queue
  → coordinator
  → output queue
  → reader
  → deallocation
```

Cancellation must drain and free every outstanding buffer.

Do not rely on destructor execution in a terminated worker thread to clean up shared queues.

## 9.5 Cancellation

Use an atomic cancellation flag.

Every potentially blocking component must observe it:

* source reads;
* job queue waits;
* result queue waits;
* worker decode loops;
* output handoff;
* coordinator waits.

When cancellation is requested:

1. close admission of new work;
2. wake all condition variables;
3. allow workers to abandon speculative jobs;
4. join every worker and auxiliary thread;
5. drain and release every buffer;
6. return a cancellation result only after cleanup.

## 9.6 Backpressure

The reader-facing output queue must be bounded.

When full:

* the coordinator blocks;
* result admission contracts;
* speculative scheduling stops expanding;
* workers eventually block on bounded result publication rather than allocating more buffers.

A slow FASTQ parser must therefore reduce CPU and memory pressure rather than allowing output to accumulate.

## 9.7 Adaptive workers

Implement fixed bounded workers first.

After correctness and baseline performance are established, add lazy and adaptive worker activation:

* configured `threads` is the maximum;
* derive a conservative bootstrap from available parallelism;
* create workers lazily;
* grow only when enough work exists;
* reduce active admission under sustained reader backpressure;
* retain a short hysteresis before retiring workers;
* do not calibrate near EOF when the cost cannot be recovered.

Treat exact adaptive heuristics as an optimisation milestone, not as part of early correctness.

---

# 10. Gzip framing

Implement gzip framing independently from zlib.

Support:

* fixed ten-byte header;
* `FEXTRA`;
* `FNAME`;
* `FCOMMENT`;
* `FHCRC`;
* concatenated members;
* empty members;
* trailing member transitions;
* BGZF `BC` subfield.

Reject:

* reserved flag bits;
* truncated optional fields;
* headers exceeding `maxHeaderSize`;
* malformed extra-field lengths;
* inconsistent BGZF `BSIZE`;
* unexpected bytes where the next verified member header is required.

A member end is authoritative only after:

1. a real final DEFLATE block;
2. byte alignment;
3. an eight-byte footer;
4. matching CRC32;
5. matching modulo-2³² ISIZE.

Never scan for gzip magic and immediately treat it as a member boundary.

---

# 11. Authoritative sequential path

Implement this before any parallel path.

Requirements:

* parse gzip framing in Nim;
* initialise bundled zlib in raw-DEFLATE mode;
* stream compressed input through bounded pages;
* stream decoded output through bounded chunks;
* compute member CRC32;
* track member ISIZE;
* verify footer;
* reset history and CRC at each member;
* continue through concatenated members;
* return detailed offsets on errors.

This path is:

* the one-thread implementation;
* the fallback for non-positional streams;
* the correctness oracle for internal differential tests;
* the recovery route after rejected speculative work.

Do not begin the marker/window implementation until this path passes the complete corruption corpus.

---

# 12. BGZF and multi-member paths

## 12.1 BGZF

Recognise BGZF only when:

* the gzip header has a valid `BC` extra subfield;
* `BSIZE` is structurally valid;
* the declared next offset lands exactly on another valid BGZF header or EOF;
* each block verifies independently.

Schedule independent BGZF blocks to workers.

A job may aggregate several adjacent BGZF blocks to reduce queue overhead, but:

* each block is inflated independently;
* each block has its own CRC32 and ISIZE verification;
* the worker must record each member’s decoded length;
* aggregation must remain bounded.

Recognise the conventional empty BGZF EOF member without special output semantics.

If a file starts like BGZF but later violates the chain, fall back to generic gzip decoding from the first uncommitted authoritative member boundary.

## 12.2 Concatenated ordinary gzip

For densely spaced ordinary members:

* discover candidate headers ahead of the coordinator;
* keep candidate storage bounded;
* independently inflate and verify candidates;
* accept a candidate only when its start equals the verified end of the preceding member;
* discard plausible gzip magic inside compressed payloads.

For large FASTQ members, avoid grouping so much work into one job that parallelism is lost.

---

# 13. DEFLATE primitives in Nim

## 13.1 Bit reader

Implement an LSB-first bit reader supporting:

* arbitrary starting bit offset;
* reading up to at least 32 bits;
* peeking without advancing;
* advancing independently;
* byte alignment;
* page-boundary refills;
* exact current compressed bit position;
* checked EOF.

Do not perform one source read per bit or symbol.

Keep a local bit accumulator, for example 64 bits, and refill in bulk.

## 13.2 Huffman tables

Implement canonical DEFLATE Huffman decoding.

Validate:

* illegal code lengths;
* oversubscribed trees;
* invalid incomplete trees;
* missing end-of-block symbol;
* invalid literal/length symbols;
* invalid distance symbols;
* illegal repeat codes in the precode;
* excessive repeats.

Start with a correct two-level lookup table.

A reasonable layout is:

```text
primary table: 8–10 bits
secondary tables: remaining bits
```

Keep table storage fixed-size and reusable per worker.

Do not allocate a new `seq` for every dynamic block.

## 13.3 Fixed and stored blocks

Implement:

* stored block length and one’s-complement validation;
* fixed Huffman trees;
* dynamic Huffman trees;
* final-block tracking;
* block-boundary reporting.

Create exhaustive unit tests around bit offsets immediately before and after byte boundaries.

---

# 14. Dynamic block finder

Implement a bounded scanner for structurally valid non-final dynamic Huffman block headers.

For each candidate:

1. interpret the possible `BFINAL` and `BTYPE`;
2. require a dynamic Huffman block where appropriate;
3. parse HLIT, HDIST and HCLEN;
4. construct the precode;
5. expand the literal/distance code lengths;
6. validate the complete trees;
7. reject impossible or incomplete candidates.

A structurally valid header is still only a candidate.

It becomes useful only when:

* complete DEFLATE decoding succeeds;
* the worker reaches a complete block boundary;
* predecessor and successor results agree on the exact compressed boundary;
* the coordinator can connect it to an authoritative predecessor.

Search regions must be bounded. If no useful boundary is found within the configured region, return a normal “no candidate” result and let the coordinator bridge the region sequentially.

---

# 15. Marker/window algorithm

This is the core ordinary-gzip parallelisation milestone.

## 15.1 Unknown predecessor history

A speculative chunk starts without knowing the preceding 32 KiB DEFLATE window.

Represent its initial history using 16-bit symbols:

```text
literal byte:       0 … 255
unknown marker: 32768 … 65535
```

Initial marker window:

```nim
history[i] = uint16(32768 + i)
```

A marker identifies the corresponding byte in the unknown predecessor window.

Do not use values 256–32767 for normal output.

## 15.2 Speculative decoding

Decode literals and matches into a bounded `uint16` output buffer.

Literal:

```text
append literal value 0…255
```

Back-reference:

```text
copy symbols from the virtual 32 KiB history/output sequence
```

The LZ77 copy must preserve overlap semantics.

For example, distance 1 and length 100 must repeatedly copy the newly appended symbol rather than copy from an immutable source slice.

Optimise long overlap copies with geometric doubling only after scalar correctness is established.

## 15.3 Virtual history

The decoder must treat:

```text
initial marker window + speculative output
```

as one logical history sequence.

Avoid maintaining both:

* a full output vector;
* a second duplicate 32 KiB ring of `uint16`.

Derive recent history directly from the output and initial marker window.

## 15.4 Marker propagation

Matches may copy:

* literal values;
* markers;
* markers that originated from earlier copied markers.

This is expected.

Marker chains should collapse naturally when the predecessor’s final window becomes known.

## 15.5 Marker-free handoff

After every complete block boundary, inspect the final 32 KiB of speculative history.

Once it contains no markers:

1. convert the final window to bytes;
2. initialise/reset the exact zlib inflater;
3. prime any partial input bits with `inflatePrime`;
4. provide the 32 KiB dictionary with `inflateSetDictionary`;
5. continue exact decoding with `Z_BLOCK`.

Do not re-decode the speculative prefix after a successful handoff.

## 15.6 Resolution

When predecessor output becomes authoritative:

1. obtain its fully resolved final 32 KiB window;
2. replace markers in the successor’s required final window;
3. unblock later successor resolution;
4. schedule complete marker replacement for the successor output;
5. compute the resolved output CRC;
6. make the resolved chunk eligible for ordered emission.

Use a 65,536-entry lookup table for large marker buffers:

```text
lookup[0…255]       = corresponding literal byte
lookup[32768…65535] = predecessor window byte
```

The scalar implementation is mandatory. SIMD is optional and later.

## 15.7 Boundary validation and fallback

The coordinator must compare:

```text
predecessor exact end bit offset
successor claimed start bit offset
```

If they differ:

* reject the speculative chain;
* discard all dependent uncommitted results;
* continue exact sequential decoding from the last authoritative boundary;
* optionally restart speculation after a later trusted point.

A false-positive block finder result is not fatal unless the authoritative decoder also finds corrupt input.

## 15.8 Speculation limit

Each speculative task must have a hard maximum decoded-symbol count.

If exceeded:

* stop speculative decoding;
* report an oversized region;
* bridge it through the exact backend;
* do not allocate a larger unbounded buffer.

---

# 16. CRC32 and member accounting

For each resolved output chunk, record:

```text
decoded length
CRC32 of actual byte output
compressed start
compressed end
member ordinal
```

Combine chunk CRCs in order using `crc32_combine`, or calculate the member CRC incrementally if measurements show combination is not beneficial.

The final member check compares:

```text
combined CRC32 == footer CRC32
decoded length modulo 2^32 == footer ISIZE
```

Reset CRC and history at every member boundary.

Never carry a dictionary from one gzip member into the next.

---

# 17. Footer recovery and exact backend details

Optimised raw inflate may read slightly beyond the logical end of the DEFLATE payload.

Implement footer recovery carefully:

* preserve enough recent compressed bytes to locate the aligned footer;
* inspect only a small bounded look-behind region;
* accept a footer position only when CRC32 and ISIZE both match;
* recognise zlib’s final-block state when `Z_BLOCK` returns before a later call would return stream end;
* never interpret footer bytes as another resumable DEFLATE block.

Add dedicated tests where:

* final DEFLATE bits end at each possible bit alignment;
* input pages end inside the footer;
* zlib has consumed bytes beyond the logical DEFLATE end;
* a false footer-like sequence occurs nearby.

---

# 18. Memory budgeting

Track live shared allocations in debug and test builds.

Derive an estimated upper bound from:

```text
activeWorkers × (
  inputPageSize
  + Huffman/scratch storage
  + maxSpeculativeOutput × sizeof(uint16)
  + exact decoded buffer
)
+ inFlightChunks × decodedChunkSize
+ reorder slack
```

When `memoryLimit` is non-zero:

* reduce in-flight count first;
* reduce active worker target second;
* reject configurations that cannot run even one worker safely.

Expose peak internally allocated bytes through `DecodeReport` and `DecoderStats`.

A test-only allocation tracker must fail tests if:

* the current live byte count underflows;
* buffers remain after cancellation;
* final live allocations are non-zero;
* the configured bound is exceeded outside a documented small tolerance.

---

# 19. SIMD and optimisation policy

Do not begin with SIMD.

Optimisation order:

1. prove correctness;
2. establish deterministic benchmarks;
3. profile;
4. improve algorithms and allocation patterns;
5. add scalar bulk operations;
6. add architecture-specific acceleration.

Potential later optimisations:

* branch-free marker lookup;
* SSE4.1 marker replacement;
* AVX2 fixed gzip-header scanning;
* NEON marker replacement;
* NEON header scanning;
* larger Huffman primary tables;
* bulk LZ77 match copies;
* input-page reuse;
* grouped BGZF jobs;
* worker-local result allocation pools.

Keep a scalar implementation available on every platform.

Runtime CPU dispatch must never execute unsupported instructions.

Prefer a small vendored C intrinsics file for SIMD kernels if Nim compiler portability becomes problematic. Such code remains internal and bundled.

---

# 20. Command-line utility

Build a binary named `gzfast`.

Minimum interface:

```text
gzfast [options] FILE
gzfast -dc [options] FILE
gzfast --verify [options] FILE
```

Options:

```text
-d, --decompress
-c, --stdout
-o, --output PATH
-t, --threads N
    --memory SIZE
    --output-limit SIZE
    --verify
    --stats
    --quiet
    --version
    --help
```

Behaviour:

* stdout is the default output for `-c`;
* refuse to write binary output to an interactive terminal unless explicitly forced;
* preserve input file by default;
* do not implement compression;
* write progress and statistics to stderr;
* never mix statistics into decompressed stdout.

Suggested exit codes:

```text
0 success
1 corrupt or truncated gzip data
2 usage or configuration error
3 input/output error
4 internal error
```

The CLI must use the same public library API as external users.

---

# 21. Test strategy

Use `std/unittest` for assertions and Testament as the test runner. Nim’s documentation recommends Testament where process isolation is useful.

`nimble test` must run the complete normal test suite.

Also provide:

```text
nimble testFast
nimble testSlow
nimble testSanitize
nimble testPackage
nimble bench
nimble docs
```

## 21.1 Unit tests

Create focused tests for:

### Bit reader

* every starting bit offset 0–7;
* reads crossing bytes;
* reads crossing input pages;
* peek and consume combinations;
* exact EOF;
* truncated bit sequences;
* 64-bit compressed positions.

### Huffman trees

* valid fixed trees;
* valid dynamic trees;
* empty distance edge cases allowed by DEFLATE;
* oversubscribed trees;
* incomplete trees;
* illegal repeat codes;
* repeat beyond target length;
* missing end-of-block;
* maximum code length.

### Gzip headers

* minimal header;
* every optional flag independently;
* all optional flags together;
* valid and invalid FHCRC;
* empty FNAME and FCOMMENT;
* oversized fields;
* truncated fields;
* reserved flags;
* multiple extra subfields;
* BGZF `BC` before or after unrelated subfields.

### Stored blocks

* every byte alignment;
* zero-length stored blocks;
* maximum stored block;
* incorrect NLEN;
* truncation between LEN and NLEN;
* truncation inside payload.

### Marker decoder

* all-literal output;
* references entirely within the chunk;
* references into unknown history;
* overlapping distance-one copies;
* matches longer than distance;
* marker propagation;
* marker-free transition;
* output-cap enforcement;
* exact final 32 KiB window.

### Marker replacement

* no markers;
* all markers;
* mixed literals and markers;
* first and last marker;
* chained predecessor windows;
* buffer lengths around vectorisation boundaries.

### Queue and cancellation

* close while empty;
* close while full;
* blocked producer cancellation;
* blocked consumer cancellation;
* repeated start and shutdown;
* injected worker failure;
* no allocation leak after every scenario.

## 21.2 Committed corpus

Commit a compact binary corpus with a manifest containing:

```text
fixture name
generator
compression level
expected decoded SHA-256
expected decoded length
member count
expected success or error kind
```

Include:

* empty gzip;
* one-byte gzip;
* small text;
* random binary;
* repetitive data;
* ordinary FASTQ;
* high-entropy FASTQ qualities;
* very long FASTQ records;
* GNU gzip levels 1, 6 and 9;
* pigz-produced input;
* fixed-Huffman stream;
* stored-block stream;
* concatenated members;
* empty members between non-empty members;
* BGZF;
* BGZF EOF block;
* gzip with large optional fields;
* gzip whose member boundary crosses an input page;
* files deliberately crafted around speculative grid points.

## 21.3 Test-only compressor

Core tests must not require a system zlib.

Compile the deflate-side zlib sources only in test builds and expose a small test helper that can generate:

* gzip members;
* raw DEFLATE;
* chosen compression levels;
* fixed strategy;
* stored strategy;
* concatenated members.

The production library remains inflate-only.

## 21.4 Differential tests

For generated plaintext:

1. compress using the test-only reference compressor;
2. decode using the authoritative sequential `gzfast` path;
3. decode using every parallel path and thread count;
4. compare exact bytes;
5. compare reports;
6. compare errors for corrupted variants.

Exercise thread counts:

```text
1, 2, 3, 4, 8
```

Exercise deliberately awkward configuration values:

```text
input pages:       31, 63, 257, 4093 bytes
output chunks:     1, 7, 64, 4097 bytes
grid points:       test-only reduced values
in-flight chunks:  1, 2, workers + 2
```

Production validation may require a 1 MiB minimum grid, but internal tests should permit smaller grids to exercise boundaries cheaply.

## 21.5 Corruption tests

Systematically mutate valid fixtures:

* flip each header bit;
* flip selected dynamic-Huffman bits;
* corrupt block lengths;
* truncate at every byte for small fixtures;
* truncate each footer byte;
* corrupt CRC32;
* corrupt ISIZE;
* inject gzip magic inside compressed payload;
* modify BGZF `BSIZE`;
* append junk;
* remove final member.

The decoder must:

* return an error;
* never hang;
* never crash;
* never read outside input;
* never exceed memory limits;
* never emit bytes beyond the verified/decoded prefix semantics.

## 21.6 Concurrency stress tests

Test:

* immediate close after open;
* close during block search;
* close during marker replacement;
* close while output queue is full;
* slow consumer;
* consumer stopping after one byte;
* repeated open/read/close loops;
* multiple independent decoders in parallel;
* worker errors arriving out of order;
* output limit reached with outstanding jobs;
* files with thousands of tiny members;
* thread budget larger than available work.

Use timeouts so deadlocks fail rather than stall CI indefinitely.

## 21.7 Large-stream tests

Create generated compressed data whose decoded size is much larger than test memory.

Read it through a small destination buffer while hashing output.

Assert:

* correct hash;
* stable internal live-allocation bound;
* no full-output allocation;
* correct report;
* complete cleanup.

The normal CI fixture need not be tens of gigabytes. A scheduled or release test should decode a genuinely large FASTQ-style corpus.

## 21.8 Sanitizers and analysis

Provide Linux jobs for:

* AddressSanitizer;
* UndefinedBehaviourSanitizer;
* Valgrind where practical.

Add ThreadSanitizer as an informational scheduled job if it works reliably with the selected Nim runtime and toolchain.

Compile test builds with normal bounds and overflow checks enabled.

---

# 22. Benchmarks

Benchmarks must not substitute for correctness tests.

Measure:

* compressed MB/s;
* decompressed MB/s;
* wall time;
* CPU time;
* maximum RSS;
* active/peak worker count;
* internal peak-buffer allocation;
* scaling efficiency.

Run with:

```text
1, 2, 4, 8, 16 threads
```

Corpus categories:

1. real Illumina FASTQ.gz;
2. high-compression repetitive FASTQ;
3. low-compression quality-heavy FASTQ;
4. GNU gzip levels 1, 6 and 9;
5. pigz output;
6. concatenated gzip;
7. BGZF;
8. random binary;
9. stored blocks;
10. many small members.

Compare against available reference tools in benchmark environments:

```text
gzip -dc
pigz -dc
rapidgzip
rapidgzip-rust
```

Use at least two output modes:

```text
decompress to null sink
decompress into a simple streaming FASTQ parser/hash
```

This separates decoder speed from filesystem output speed.

Initial performance goals, not correctness requirements:

* one-thread performance reasonably close to bundled zlib;
* clear speed-up at four threads on large ordinary gzip;
* continued scaling on suitable inputs;
* no file-size-dependent growth in RSS;
* no severe regression when the consumer is slower than the decoder.

Do not enforce noisy throughput thresholds on ordinary shared CI runners. Store benchmark history and use a dedicated runner for regression gates.

---

# 23. CI matrix

At minimum:

```text
Ubuntu x86-64, GCC, Nim stable
Ubuntu x86-64, Clang, Nim stable
Ubuntu x86-64, GCC, Nim devel
macOS Apple Silicon, Nim stable
Windows x86-64, Nim stable
```

Additional scheduled jobs:

```text
Linux AArch64
sanitizers
Valgrind
large corpus
benchmark regression
Nim devel allow-failure
```

Every normal CI run must:

1. build debug tests;
2. run unit tests;
3. run integration tests;
4. run concurrency tests;
5. build release CLI;
6. run the CLI against fixtures;
7. generate documentation;
8. create a Nimble package;
9. install that package into a clean Nimble directory;
10. compile a separate consumer project;
11. inspect linked dependencies.

Dependency inspection:

```text
Linux:   ldd and readelf -d
macOS:   otool -L
Windows: dumpbin /dependents or objdump -p
```

Fail if a compression runtime such as `libz` or `zlib1.dll` appears.

System C runtime dependencies are acceptable.

---

# 24. Documentation requirements

The README must begin with the normal user experience:

```nim
import gzfast

let input = openGzFast("reads.fastq.gz", threads = 8)
defer:
  input.close()

for line in input.lines:
  discard line

discard input.finish()
```

Clearly document:

* `--threads:on`;
* no system zlib requirement;
* forward-only output;
* bounded memory;
* path-based input gets parallel decoding;
* non-positional streams use sequential fallback;
* CRC and ISIZE verification;
* concatenated gzip support;
* BGZF support;
* cancellation and `finish()` semantics;
* output chunks do not align to FASTQ lines or records.

Generate API documentation from exported doc comments.

Add runnable examples for all major public APIs.

`ARCHITECTURE.md` must describe:

* data flow;
* source abstraction;
* bounded queues;
* worker ownership;
* path selection;
* marker/window symbols;
* marker resolution;
* exact fallback;
* cancellation;
* memory bounds.

---

# 25. Implementation milestones

Do not implement the whole project in one patch.

Each milestone must leave the repository compiling, documented and tested.

## Milestone 0 — Project skeleton

Deliver:

* Nimble package;
* directory layout;
* CI skeleton;
* public placeholder API;
* licences and upstream notices;
* `nimble test`;
* `nimble docs`;
* one minimal consumer example.

Acceptance:

* clean Nimble package installation;
* no untracked generated files;
* CI works on Linux, macOS and Windows.

## Milestone 1 — Vendored zlib backend

Deliver:

* zlib 1.3.2 source;
* project-specific symbol prefix;
* C shim;
* private Nim bindings;
* raw inflate smoke tests;
* CRC32 and CRC combination tests;
* binary dependency inspection.

Acceptance:

* decompress a small raw-DEFLATE fixture;
* no system zlib headers or library;
* no public zlib symbols;
* no memory leak across repeated inflater reset.

## Milestone 2 — Sequential verified gzip decoder

Deliver:

* gzip parser;
* concatenated-member support;
* CRC32 and ISIZE verification;
* bounded sequential input/output;
* corruption errors with offsets;
* output limit.

Acceptance:

* all committed valid fixtures decode correctly;
* all basic corruption fixtures fail correctly;
* arbitrarily large output can be consumed with bounded memory.

## Milestone 3 — Public reader and direct-output API

Deliver:

* `GzFastDecoder`;
* `GzFastConfig`;
* `GzFastStream`;
* `openGzFast`;
* `decodeTo`;
* `finish`, `close`, `cancel`;
* reports and public errors;
* CLI using the public API.

Acceptance:

* examples compile from the packed Nimble archive;
* early close does not leak or leave threads;
* direct and reader APIs produce identical output and reports.

## Milestone 4 — Positional source and worker infrastructure

Deliver:

* `ReadAtSource`;
* POSIX and Windows positional I/O;
* bounded queues;
* worker lifecycle;
* shared buffers;
* cancellation;
* ordered result coordinator;
* allocation tracking.

Acceptance:

* synthetic out-of-order jobs are emitted in order;
* all queue cancellation tests pass;
* multiple decoder instances can run concurrently;
* no final shared allocations remain.

## Milestone 5 — BGZF and multi-member parallelism

Deliver:

* BGZF parser;
* validated block chain;
* BGZF parallel jobs;
* concatenated-member candidate scanner;
* ordered member verification;
* fallback on inconsistent candidates.

Acceptance:

* BGZF and concatenated fixtures scale across workers;
* every footer is independently verified;
* false member candidates are rejected;
* mixed or malformed BGZF safely falls back or errors.

## Milestone 6 — Pure Nim DEFLATE structures

Deliver:

* arbitrary-offset bit reader;
* fixed Huffman tables;
* dynamic Huffman parser;
* stored blocks;
* reusable decode tables;
* dynamic-header block finder.

Acceptance:

* exhaustive unit tests;
* no allocation per decoded symbol;
* invalid trees are rejected;
* block candidates are correctly reported with bit offsets.

## Milestone 7 — Marker decoder

Deliver:

* `uint16` marker representation;
* virtual unknown history;
* literal and LZ77 decoding;
* overlap semantics;
* bounded speculative output;
* marker-free dictionary detection;
* exact zlib handoff.

Acceptance:

* differential tests against known predecessor windows;
* all overlap and marker propagation tests pass;
* exact handoff output equals authoritative sequential output.

## Milestone 8 — Marker resolution and ordinary gzip parallel path

Deliver:

* compressed grid scheduling;
* candidate block discovery;
* speculative chunk jobs;
* predecessor window resolution;
* full marker replacement jobs;
* exact boundary matching;
* ordered output;
* sequential bridge and fallback.

Acceptance:

* ordinary single-member gzip decodes correctly at multiple thread counts;
* forced false candidates recover correctly;
* output is byte-identical to sequential decoding;
* CRC32 and ISIZE verify;
* memory remains bounded.

## Milestone 9 — Robustness and stress hardening

Deliver:

* full corruption matrix;
* cancellation stress;
* slow-consumer tests;
* output-limit stress;
* large-stream test;
* sanitizer jobs;
* fuzz harnesses.

Acceptance:

* no hangs;
* no leaks;
* no out-of-bounds access;
* no invalid success on corrupted input;
* all worker shutdown paths are deterministic.

## Milestone 10 — Performance work

Deliver:

* profiling report;
* allocation reductions;
* bulk LZ77 copying;
* faster marker replacement;
* optional SIMD;
* grouped BGZF work;
* lazy/adaptive worker controller;
* benchmark automation.

Acceptance:

* no correctness regression;
* meaningful multithread speed-up on large ordinary FASTQ.gz;
* stable memory use;
* scalar fallback still passes the full test suite.

## Milestone 11 — Release preparation

Deliver:

* complete README;
* API docs;
* architecture documentation;
* changelog;
* package-install validation;
* release corpus results;
* benchmark report;
* licence audit;
* versioned `0.1.0` release candidate.

Do not call the implementation `1.0` until the ordinary gzip marker path has been tested broadly on real-world gzip producers and all primary platforms.

---

# 26. Coding rules for Codex

Follow these throughout implementation:

1. Prefer clear Nim over literal C++ or Rust syntax translation.
2. Use Nim naming conventions: `camelCase` for procedures and fields, `PascalCase` for types.
3. Keep file and bit offsets as distinct internal types where practical.
4. Use checked arithmetic for externally derived lengths and offsets.
5. Do not cast away type safety outside isolated low-level modules.
6. Explain every `cast`, raw pointer and shared allocation with a comment.
7. No global mutable decoder state.
8. No `readAll`.
9. No unbounded queue.
10. No file-size-proportional index.
11. No output-size-proportional allocation.
12. No worker may write directly to a user sink.
13. No worker may raise an exception across a thread boundary.
14. No guessed boundary becomes authoritative without exact validation.
15. No optimisation may remove scalar fallback tests.
16. Add a regression test before fixing every discovered decoder bug.
17. Keep test-only compression code out of production builds.
18. Keep all vendored modifications documented.
19. Run formatting, tests and package-install validation after every milestone.
20. Update `ARCHITECTURE.md` whenever ownership or scheduling behaviour changes.

---

# 27. Definition of done

`gzfast` is complete when all of the following are true:

* It installs from Nimble.
* A consuming Nim program needs no system compression library.
* The packed package contains all required C sources and licences.
* It streams files much larger than RAM.
* Memory use is bounded and measured.
* It supports ordinary gzip, concatenated gzip and BGZF.
* It verifies CRC32 and ISIZE for every member.
* It handles corrupt and truncated files without crashing or hanging.
* It provides both a `Stream` API and a direct-output API.
* It can cancel and cleanly join all work.
* The one-thread path is a dependable correctness oracle.
* Ordinary single-member gzip gains real multithreaded speed-up.
* Output is identical for all supported thread counts.
* Linux, macOS and Windows CI pass.
* Sanitizer and stress tests pass.
* The produced executable has no `libz` or `zlib1.dll` dependency.
* The README contains complete, runnable examples.
* Every upstream-derived component has appropriate attribution.


# Writer benchmark

`bench_writer.nim` measures the `GzFastWriter` API against system `gzip` and
single-threaded `pigz` at compression levels 1, 6, and 9. It is intended to
document normal writer performance and detect regressions. It is not a claim
that gzfast should outperform pigz.

## Workloads

The harness generates deterministic inputs so repeated runs use identical
bytes and CRC32 values:

- `text`: structured, log-like generic text with varying numeric fields.
- `random`: pseudo-random bytes representing incompressible input.
- `fastq`: four-line, 150-base FASTQ-shaped records with varying identifiers,
  sequences, and quality characters.

The default size is 64 MiB per workload. Generation and correctness checking
are outside the timed region. Every output is decoded with gzfast and checked
against the source byte count and CRC32.

## Running

```bash
nimble benchWriter
benchmarks/bench_writer --require-pigz --repeat 3 --warmup 1 \
  > writer-bench.csv
benchmarks/bench_writer --summary writer-bench.csv \
  > writer-summary.csv
```

Use a smaller matrix while developing:

```bash
benchmarks/bench_writer --size 8MiB --repeat 1 --warmup 0
```

`pigz` is optional by default and emits a warning when unavailable. Release
measurements should pass `--require-pigz`. `gzip -n` and `pigz -n` suppress
filename and timestamp metadata so compressed sizes are reproducible.

## Interpreting results

Raw CSV contains wall time, gzfast process CPU time, throughput, compressed
size, compression ratio, and exit status. External-tool CPU time is omitted
because those processes are not children accounted by Nim's `cpuTime()`.

Summary `speedup_vs_*` values are baseline wall time divided by the row's wall
time. Values above 1 mean the row is faster than that baseline. Compare only
runs from the same machine, operating system, Nim/C compiler, power mode, and
tool versions.

The gzfast API runs in-process, while external tools include process startup.
At the default 64 MiB size this is normally a small part of elapsed time; tiny
development runs should not be used for performance claims.

Expected invariants:

- all variants exit successfully and pass byte-count/CRC verification;
- random-data compression ratio remains close to 1.0;
- text and FASTQ-shaped data compress substantially;
- matching gzfast and `gzip` levels normally have equal or very similar sizes
  because both use the same zlib deflater family;
- pigz output size may differ slightly even with `-p1`.

For regression review, keep raw and summary CSV together. Treat a repeatable
wall-time or throughput change of roughly 10% as an investigation trigger,
not an automatic failure: rerun after controlling machine load and inspect
compression ratio at the same time. Any correctness failure or unexplained
material ratio change is a release blocker.

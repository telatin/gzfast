# Benchmark datasets

`generate_corpus.nim` creates deterministic local datasets:

| File | Purpose |
|---|---|
| `marker-multiblock-64m.gz` | 384 approximately-171-KiB fixed output blocks, each preceded by a genuine dynamic candidate within the next grid-search window; successful marker scaling and match-copy pressure |
| `marker-fallback-64m.gz` | One large high-ratio block beyond the speculative cap; fallback overhead |
| `bgzf-repeated.gz` | 512 repetitions of the committed three-block BGZF unit; block scheduling overhead |
| `members-10000.gz` | 10,000 one-byte ordinary members; dense-member scheduling overhead |
| `fastq-single-64m.fastq.gz` | FASTQ-shaped single-member gzip; production-like ordinary gzip without biological parsing assumptions |
| `fastq-concat-64m.fastq.gz` | FASTQ-shaped concatenated gzip with 64 members; realistic member-parallel scheduling control |
| `fastq-bgzf-32m.bgzf.fastq.gz` | FASTQ-shaped BGZF-like stream with 512 blocks; realistic BGZF scaling control |
| `log-lines-8m.log.gz` | Line-oriented non-FASTQ text encoded as fixed Huffman literals; generic gzip decode cost |
| `stored-random-8m.gz` | Stored-block pseudo-random bytes; low-compression I/O-heavy behavior |

The core release driver runs worker budgets `1, 2, 4, 8, 16` over the
marker/BGZF/member stress files, verifies every footer, computes a decoded
CRC, asserts the report byte count, and emits CSV with path selection,
wall/CPU time, MiB/s, peak workers and accounted peak buffering. The
Phase 3 `bench-controls` target runs `benchmarks/bench_fastq` over generated
FASTQ-shaped and generic gzip controls to cover single-member,
concatenated-member, BGZF, text/literal and stored-block layouts with the same
real-file CSV schema used for production inputs.
Large real FASTQ and comparison tools remain environment-specific release
benchmarks and must record input checksums and hardware details.

For Phase 3 production benchmarking, use `benchmarks/bench_fastq` as a
real-file harness over a mixed gzip workload rather than FASTQ alone. A useful
matrix is:

| Workload | Purpose |
|---|---|
| ordinary single-member FASTQ.gz | primary production target and current default sequential path |
| BGZF FASTQ or BGZF-like blocks | independent-member scaling and ordered output |
| concatenated-member FASTQ.gz | gzip member-parallel scheduling without FASTQ-specific logic |
| non-FASTQ text/log gzip | general gzip behavior on line-oriented data |
| repetitive gzip | high-compression decode/copy pressure |
| random-ish gzip | low-compression I/O-heavy behavior |
| stored-block gzip | stored-block correctness and future stored-path benchmarking |

The harness records a coarse `workload` column inferred from file names. Use
descriptive input names such as `sample.fastq.gz`, `sample.bgzf.fastq.gz`,
`sample.concat.fastq.gz`, `run.log.gz`, `stored.gz` and `random.gz` so
summaries can be filtered without parsing file contents.

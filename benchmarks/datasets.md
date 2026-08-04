# Benchmark datasets

`generate_corpus.nim` creates three deterministic local datasets:

| File | Purpose |
|---|---|
| `marker-multiblock-64m.gz` | 384 approximately-171-KiB fixed output blocks, each preceded by a genuine dynamic candidate within the next grid-search window; successful marker scaling and match-copy pressure |
| `marker-fallback-64m.gz` | One large high-ratio block beyond the speculative cap; fallback overhead |
| `bgzf-repeated.gz` | 512 repetitions of the committed three-block BGZF unit; block scheduling overhead |
| `members-10000.gz` | 10,000 one-byte ordinary members; dense-member scheduling overhead |

The release driver runs worker budgets `1, 2, 4, 8, 16`, verifies every
footer, computes a decoded CRC, asserts the report byte count, and emits CSV
with path selection, wall/CPU time, MiB/s, peak workers and accounted peak
buffering. Large real FASTQ and comparison tools remain environment-specific
release benchmarks and must record input checksums and hardware details.

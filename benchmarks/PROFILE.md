# Milestone 10 profile and optimization report

Environment used for the local measurements:

```text
Apple M1 Max
macOS Darwin 25.5.0
Nim 2.2.10, amd64/Rosetta backend
-d:release --threads:on --mm:orc
```

Results are workload/hardware specific and are not CI thresholds. Run
`nimble bench` for the complete current matrix.

## Baseline findings

The first high-ratio ordinary fixture had only one useful candidate and
correctly exceeded the speculative cap. It measured about 449 MiB/s on the
sequential path and 237–242 MiB/s after mixed marker/fallback overhead. This
led to separating successful-marker and fallback benchmark datasets.

On the corrected 64 MiB multi-boundary marker dataset, the initial scalar,
eager-allocation implementation measured approximately:

| Budget | MiB/s | Peak accounted bytes |
|---:|---:|---:|
| 2 | 69 | 33.6 MiB |
| 4 | 85 | 50.4 MiB |
| 8 | 54–93 | 83.9 MiB |
| 16 | 79–93 | 151.0 MiB |

The hot code inspection matched the upstream profile: marker LZ77 copying
performed capacity/metadata work for every symbol, full resolution was
branch-heavy, and each task eagerly allocated twice its maximum symbol count.

## Accepted changes

### Bulk LZ77 and lazy marker growth

* Whole-match capacity validation and one reserve.
* Virtual predecessor marker run materialization.
* Non-overlapping first-period `copyMem`.
* Geometric overlap doubling.
* Marker count and logical length updated per run/match.
* Marker buffers begin at at most 64 Ki symbols and grow geometrically under
  the unchanged hard cap.
* Scalar implementation retained as a differential oracle.

This reduced accounted peaks to approximately 2–9 MiB and raised marker
throughput to roughly 79–93 MiB/s.

### Marker replacement and persistent marker runtime

* Direct pointer scalar replacement.
* Complete-window 65,536-byte lookup table for buffers at least 128 KiB.
* `copyMem` rolling-window maintenance.
* Persistent source, queues, threads, inflater/Huffman workspaces and
  coordinator across marker batches.
* Copy-free verify-only draining.

After persistent workers, direct replacement, one-probe finding, and the
final release run, marker throughput reached approximately:

| Budget | MiB/s | Peak accounted bytes |
|---:|---:|---:|
| 2 | 202 | 2.1 MiB |
| 4 | 223 | 3.1 MiB |
| 8 | 226 | 5.3 MiB |
| 16 | 223 | 9.5 MiB |

The synthetic repetitive stream remains faster in mature zlib sequentially
(about 460 MiB/s), which is expected: it is exceptionally favorable to
optimized exact inflate and is not representative proof of multicore FASTQ
scaling.

### BGZF grouping

Up to eight adjacent validated BGZF blocks now share one aggregate worker job
and result allocation while each block still resets inflate and independently
verifies BSIZE, CRC32 and ISIZE.

| Budget | Before | After |
|---:|---:|---:|
| 2 | 1.30 GiB/s | 1.67 GiB/s |
| 4 | 1.52 GiB/s | 2.16 GiB/s |
| 8 | 1.57 GiB/s | 2.15 GiB/s |
| 16 | 1.55 GiB/s | 2.11 GiB/s |

### Tiny-member admission

10,000 one-byte members measured only 0.03–0.07 MiB/s with one job per member,
versus about 2.2 MiB/s sequentially. A bounded dense/sub-256-byte probe now
selects the authoritative sequential path, restoring about 2.4–2.5 MiB/s for
larger requested budgets until safe ordinary-member grouping is implemented.

### Worker bootstrap and output paths

* Automatic worker budgets above four use `ceil(2 * sqrt(maximum))` as the
  conservative initial target; explicit budgets remain explicit.
* Marker batches reuse one persistent pool.
* Verify-only releases already-accounted parallel buffers without copying to
  scratch.
* File output avoids `FileStream` virtual dispatch, though public output still
  contains one caller-buffer copy.

## SIMD decision

No architecture-specific SIMD was added. Large complete-window replacement
already uses a branch-light lookup table. Upstream's AVX2 marker-patching
experiment regressed on Broadwell, and current measurements point to native
decode/scheduling rather than scalar replacement as the dominant remaining
cost. Scalar implementations remain the required oracle on all platforms.

## Remaining measured opportunities

* Real FASTQ benchmarks on native AArch64/x86-64 hardware.
* Generation-tagged empirical worker growth/retirement after sufficient work.
* Ordinary-member grouping for tiny members instead of sequential admission.
* Backend-specific zero-copy `drainTo` for resolved/member buffers.
* Unified internal memory accounting plus external peak RSS collection.

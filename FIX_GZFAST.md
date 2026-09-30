# Plan: fix the gzfast multi-member livelock

## Summary

SeqFu (via readfx 0.8.0, which uses gzfast 0.3.0) hangs or crawls on large
**multi-member gzip** files. The cause is a livelock in gzfast's parallel
member decoder. SeqFu's own code is not at fault. The fix is a one-line change
in gzfast, followed by releases of gzfast, readfx and SeqFu, in that order.

Reported case: `/tmp/local/SRR30521510_rRNA_1.fq.gz` (228 MB compressed,
2.36 GB decompressed, 32 members, 7,252,812 reads).

| Command                                   | Before          | After patch |
|-------------------------------------------|-----------------|-------------|
| `seqkit stats --all` (reference)          | 25.5 s          | n/a         |
| `seqfu stats file.gz`                     | >90 s (killed)  | 3.65 s      |
| `seqfu count file.gz`                     | >90 s (killed)  | 2.7 s       |
| `gzfast --verify file.gz`                 | >60 s (killed)  | 2.15 s      |
| `gzfast --verify -t 1 file.gz`            | 2.1 s           | 2.1 s       |
| `gzip -cd file.gz \| seqfu stats`         | 1.3 s           | n/a         |

Patched SeqFu output matches seqkit: 7,252,812 reads, 937,733,597 bp,
min 35, max 150.

## Root cause

File: `src/gzfast/paths/member_parallel.nim`, proc `prepareNext`, line 288
(tag `v0.3.0`, commit `130cf8b`; still present on `main`).

1. With `threads = 0` (auto, the readfx default), a file whose first bytes
   show two or more gzip headers is routed to the parallel member path
   (`pmmMultiMember`).
2. A worker's output for one member is capped at `maxSpeculativeOutput`
   (default 16 MiB). If a member decodes to more than that, `processMember`
   returns `weOutputCap`. `failedMember` turns that into `jrsRejected`, even
   for the authoritative job.
3. `acceptResult` handles the rejection by setting `chainBroken = true` and
   `fallbackOffset = expectedStart`. It does **not** set `planningDone`.
4. On the next pass of the `prepareNext` loop, with `inFlight == 0`, the
   branch `elif decoder.inFlight == 0 and not decoder.planningDone:` runs
   first. It calls `scheduleMemberBatch()` again from the same
   `expectedStart`, so `inFlight` is non-zero again. The
   `if decoder.chainBroken: startFallback(...)` check below it is never
   reached.
5. The same batch is decoded up to the 16 MiB cap and rejected, over and over.
   This burns about 1.6 cores forever, which matches `user > real` in the
   original report.

Trigger condition: **two or more gzip members, at least one of which
decompresses to more than 16 MiB.** That is the normal layout of files made
with `cat a.gz b.gz`, `gzip -c x >> y.gz`, SRA dumps and merged lanes. Many
small members (for example 50 × 320 KB) and single-member files are
unaffected.

## Step 1: gzfast (github.com/telatin/gzfast), release 0.3.1

### 1a. Fix

In `src/gzfast/paths/member_parallel.nim`, `prepareNext`:

```nim
    elif decoder.inFlight == 0 and not decoder.planningDone and
         not decoder.chainBroken:
      decoder.batchActive = false
      decoder.scheduleMemberBatch()
```

This was checked against a patched copy of 0.3.0 (see the table above). The
fallback then takes over at `expectedStart`, and the report shows
`paths=dpSequential+dpMultiMember+dpMixed` with `crcVerified=true`.

Optional hardening, to do in the same PR:
- In `acceptResult`, when setting `chainBroken`, also call
  `closeAdmission()` and set `planningDone = true`. The state then can't be
  re-scheduled, whatever order the loop checks things in.
- Add a debug assertion or loop guard: if `scheduleMemberBatch` is called
  twice with the same `expectedStart`, and nothing was accepted in between,
  raise `geInternal` instead of spinning.

### 1b. Regression tests (under `tests/integration` or `tests/concurrency`)

Generate fixtures at test time. Do not commit large binaries.
- **Big members:** 2 members, each decompressing to about 20 MiB (above the
  16 MiB cap). Use data that compresses realistically, such as synthetic
  FASTQ from a seeded RNG.
- **Mixed sizes:** a small member, then a big one, then a small one. This
  covers a fallback that starts in the middle of the stream.
- **Big member first, then many tiny ones.**
- **Control:** 50 small members, which must stay on `dpMultiMember` alone.

For each one, check:
- The decoded bytes equal the concatenated plain input (a byte comparison or
  a CRC).
- The member count is correct, and `crcVerified` is true.
- Tests run with `threads = 0` and with explicit `threads = 4`.
- **A wall-clock guard**, for example the test fails if decoding takes more
  than 10 s. Without it, a regression hangs CI instead of failing it.

Also exercise the stdin/sequential entry (`openGzFastSequential`) with the
same fixtures, to confirm it is unaffected.

### 1c. Release

- Bump `gzfast.nimble` to `0.3.1` and add a `CHANGELOG.md` entry
  ("Fix livelock decoding concatenated gzip members larger than
  maxSpeculativeOutput").
- Tag `v0.3.1`.

### 1d. Follow-up (separate issue, not blocking)

Once the fallback triggers, everything after it is decoded sequentially, so
later members lose parallelism. Consider giving large members their own
larger output budget, or streaming them in chunks, instead of falling back
for the rest of the file. With the patch, decoding is already on par with
system `gzip -cd`, so this is only an optimisation.

## Step 2: readfx (quadram-institute-bioscience/readfx), release 0.8.1

- `readfx.nimble`: `requires "nim >= 2.2.0", "gzfast >= 0.3.1"`.
- Add a test to the readfx suite: `readFQ` on a generated FASTQ file with
  2 big members, checking the record count and the first and last records,
  with a time guard.
- Keep `readfxGzfastThreads` (default 0) as is. Document
  `-d:readfxGzfastThreads=1` as the switch that turns off parallel decoding.
- Bump the version and tag `v0.8.1`.

## Step 3: SeqFu (this repo)

- `seqfu.nimble`: `requires "readfx >= 0.8.1"` (and optionally
  `requires "gzfast >= 0.3.1"` directly, so a stale gzfast can't be
  resolved).
- Bump the SeqFu version in `seqfu.nimble`.
- Add `test/test-multimember.sh`, sourced from `test/mini.sh` and following
  the rules in AGENTS.md (it must update `PASS` and `ERRORS` and set defaults
  when run directly):
  - Build the fixture at runtime: take about 25 MB of FASTQ (for example
    `data/` files concatenated, or a generated file), then
    `gzip -c part >> multi.fq.gz` twice.
  - Run `seqfu count` and `seqfu stats` under a timeout. macOS has no
    `timeout`, so use `perl -e 'alarm 30; exec @ARGV' ...`.
  - Check that the counts and total bp equal the output of
    `gzip -cd multi.fq.gz | seqfu stats`, which serves as the reference.
- Run `bash test/mini.sh`, then `make test`, then `git diff --check`.
- Add a release-notes line: "Fixed hang or extreme slowdown on
  concatenated/multi-member .gz inputs (gzfast livelock)".

## Workarounds until released

- `zcat file.gz | seqfu <cmd>`: stdin uses gzfast's sequential path.
- Build SeqFu with `-d:readfxGzfastThreads=1`.

## Reproducer (for the bug report)

```bash
# ~32 MB plain FASTQ chunk; any data that decompresses to more than 16 MiB works
head -400000 reads.fq > p.fq
gzip -c p.fq >  m2.gz
gzip -c p.fq >> m2.gz
gzfast --verify --stats m2.gz        # hangs on 0.3.0
gzfast --verify --stats -t 1 m2.gz   # about 0.3 s
```

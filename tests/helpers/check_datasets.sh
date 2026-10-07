#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gzfast-datasets.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/tests/helpers" "$TEST_DIR/tests/datasets" "$TEST_DIR/bin" "$TEST_DIR/elsewhere"
cp "$PROJECT_DIR/tests/DATASETS.sh" "$TEST_DIR/tests/"
cp "$PROJECT_DIR/tests/helpers/fastq_subset.awk" "$TEST_DIR/tests/helpers/"
# An unexpected network call must fail, including on repeated preparation.
printf '#!/bin/sh\nexit 99\n' > "$TEST_DIR/bin/curl"
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"

cat > "$TEST_DIR/reads.fastq" <<'EOF'
@r1
AC
GT
+
II
II
@r2
ACGT
+
IIII
@r3
ACGT
+
IIII
@r4
ACGT
+
IIII
@r5
ACGT
+
IIII
@r6
ACGT
+
IIII
@r7
ACGT
+
IIII
@r8
ACGT
+
IIII
EOF
gzip -n -c "$TEST_DIR/reads.fastq" > "$TEST_DIR/tests/datasets/ERR6797445_R1.fastq.gz"
cp "$TEST_DIR/tests/datasets/ERR6797445_R1.fastq.gz" "$TEST_DIR/tests/datasets/nanopore.fastq.gz"
cd "$TEST_DIR/elsewhere"
QUICK_BYTES=1 bash "$TEST_DIR/tests/DATASETS.sh" --no-controls
gzip -dc "$TEST_DIR/tests/datasets/nanopore-quarter.fastq.gz" > "$TEST_DIR/quarter.fastq"
head -n 10 "$TEST_DIR/reads.fastq" > "$TEST_DIR/expected-quarter.fastq"
cmp "$TEST_DIR/quarter.fastq" "$TEST_DIR/expected-quarter.fastq"
gzip -dc "$TEST_DIR/tests/datasets/illumina-small.fastq.gz" > "$TEST_DIR/small.fastq"
head -n 6 "$TEST_DIR/reads.fastq" > "$TEST_DIR/expected-small.fastq"
cmp "$TEST_DIR/small.fastq" "$TEST_DIR/expected-small.fastq"
awk -F '\t' '$1 == "nanopore-quarter.fastq.gz" { found=1; if ($4 != 2 || $5 != 34) exit 1 } END { if (!found) exit 1 }' \
  "$TEST_DIR/tests/datasets/datasets.tsv"

OVERRIDE="$TEST_DIR/custom output"
mkdir -p "$OVERRIDE"
cp "$TEST_DIR/tests/datasets/ERR6797445_R1.fastq.gz" "$TEST_DIR/tests/datasets/nanopore.fastq.gz" "$OVERRIDE/"
OUTDIR="$OVERRIDE" QUICK_BYTES=1 NANOPORE_DIVISOR=2 bash "$TEST_DIR/tests/DATASETS.sh" --no-controls
gzip -dc "$OVERRIDE/nanopore-half.fastq.gz" > "$TEST_DIR/half.fastq"
head -n 18 "$TEST_DIR/reads.fastq" > "$TEST_DIR/expected-half.fastq"
cmp "$TEST_DIR/half.fastq" "$TEST_DIR/expected-half.fastq"

if [[ ${CHECK_DATASET_CONTROLS:-0} == 1 ]]; then
  OUTDIR="$OVERRIDE" QUICK_BYTES=1 bash "$PROJECT_DIR/tests/DATASETS.sh"
  awk -F '\t' 'END { if (NR != 14) exit 1 }' "$OVERRIDE/datasets.tsv"
  awk -F '\t' '$1 == "fastq-bgzf-32m.bgzf.fastq.gz" { found=1; if ($4 <= 0 || $5 <= 0) exit 1 } END { if (!found) exit 1 }' \
    "$OVERRIDE/datasets.tsv"
fi

compressed_size=$(wc -c < "$OVERRIDE/ERR6797445_R1.fastq.gz")
dd if="$OVERRIDE/ERR6797445_R1.fastq.gz" of="$TEST_DIR/truncated.gz" \
  bs=1 count="$(( compressed_size - 1 ))" 2>/dev/null
if gzip -dc "$TEST_DIR/truncated.gz" |
    awk -v maxRecords=1 -f "$PROJECT_DIR/tests/helpers/fastq_subset.awk" > /dev/null; then
  printf 'Expected a truncated gzip trailer to fail\n' >&2; exit 1
fi

# A bad final record must still fail even when only the first read is selected.
printf '@broken\nACGT\n+\nII\n' >> "$TEST_DIR/reads.fastq"
if awk -v maxRecords=1 -f "$PROJECT_DIR/tests/helpers/fastq_subset.awk" "$TEST_DIR/reads.fastq" > /dev/null; then
  printf 'Expected truncated FASTQ to fail\n' >&2; exit 1
fi
if QUICK_BYTES=0 bash "$TEST_DIR/tests/DATASETS.sh" --no-controls; then
  printf 'Expected invalid byte target to fail\n' >&2; exit 1
fi
printf 'Dataset preparation checks passed\n'

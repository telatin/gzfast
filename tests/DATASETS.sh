#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tests/DATASETS.sh [--no-controls]

Download or reuse verified Illumina and Nanopore FASTQ files, then prepare:
  illumina-small.fastq.gz       about 512 MiB decoded, complete reads
  nanopore-quarter.fastq.gz     first quarter of the Nanopore reads
  generated gzip/BGZF controls  unless --no-controls is supplied
  datasets.tsv                 compressed SHA-256, records and decoded bytes

OUTDIR defaults to tests/datasets, independent of the working directory.
QUICK_BYTES sets the small subset's decoded byte target (default 536870912).
NANOPORE_DIVISOR=2 selects nanopore-half.fastq.gz instead of a quarter.
Full downloads are retained for resume/reuse. Preparation streams through
the complete inputs to check gzip integrity, so it can take several minutes.
EOF
}

CONTROLS=1
case ${1:-} in
  --help|-h) usage; exit 0 ;;
  --no-controls) CONTROLS=0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac
if (( $# > 1 )); then usage >&2; exit 2; fi

export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTDIR=${OUTDIR:-"$SCRIPT_DIR/datasets"}
QUICK_BYTES=${QUICK_BYTES:-536870912}
NANOPORE_DIVISOR=${NANOPORE_DIVISOR:-4}
if [[ ! $QUICK_BYTES =~ ^[1-9][0-9]*$ ]]; then
  printf 'QUICK_BYTES must be a positive integer\n' >&2; exit 2
fi
case $NANOPORE_DIVISOR in
  2) NANOPORE_SUBSET=nanopore-half.fastq.gz ;;
  4) NANOPORE_SUBSET=nanopore-quarter.fastq.gz ;;
  *) printf 'NANOPORE_DIVISOR must be 2 or 4\n' >&2; exit 2 ;;
esac
mkdir -p "$OUTDIR"
OUTDIR=$(CDPATH= cd -- "$OUTDIR" && pwd)
WORKDIR=$(mktemp -d "$OUTDIR/.prepare.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

inspect() {
  gzip -dc -- "$1" | awk -v statsOnly=1 -f "$SCRIPT_DIR/helpers/fastq_subset.awk" > "$2"
}

download() {
  # Validate existing files before skipping curl; incomplete downloads resume.
  if [[ -s "$OUTDIR/$2" ]] && inspect "$OUTDIR/$2" "$WORKDIR/$2.stats"; then
    printf 'Reusing verified %s\n' "$OUTDIR/$2"
    return
  fi
  printf 'Downloading %s\n' "$OUTDIR/$2"
  curl --fail --location --retry 5 --retry-delay 5 --retry-connrefused \
    --connect-timeout 30 -C - --output "$OUTDIR/$2" "$1"
  inspect "$OUTDIR/$2" "$WORKDIR/$2.stats"
}

subset() {
  printf 'Preparing %s\n' "$OUTDIR/$2"
  # The selector drains input instead of exiting early like head: pipefail
  # therefore catches corrupt trailers without treating SIGPIPE as success.
  gzip -dc -- "$OUTDIR/$1" |
    awk -v maxRecords="$3" -v maxBytes="$4" \
      -v reportFile="$WORKDIR/$2.stats" -f "$SCRIPT_DIR/helpers/fastq_subset.awk" |
    gzip -n -6 > "$WORKDIR/$2"
  gzip -t -- "$WORKDIR/$2"
  mv -- "$WORKDIR/$2" "$OUTDIR/$2"
}

# Illumina reads
EBI="ftp://ftp.sra.ebi.ac.uk/vol1/fastq"
download "$EBI/ERR679/005/ERR6797445/ERR6797445_1.fastq.gz" ERR6797445_R1.fastq.gz

# Nanopore
NANO_URL="https://nanopore.s3.climb.ac.uk/Zymo-GridION-EVEN-BB-SN.fq.gz"
download "$NANO_URL" nanopore.fastq.gz

subset ERR6797445_R1.fastq.gz illumina-small.fastq.gz 0 "$QUICK_BYTES"
read -r nanopore_records nanopore_bytes < "$WORKDIR/nanopore.fastq.gz.stats"
subset_records=$(( nanopore_records / NANOPORE_DIVISOR ))
if (( subset_records == 0 )); then
  printf 'Nanopore input has too few records for the requested fraction\n' >&2
  exit 1
fi
subset nanopore.fastq.gz "$NANOPORE_SUBSET" "$subset_records" 0

files=(ERR6797445_R1.fastq.gz nanopore.fastq.gz illumina-small.fastq.gz "$NANOPORE_SUBSET")
if (( CONTROLS )); then
  cd -- "$PROJECT_DIR"
  nim c -d:release --threads:on --mm:orc -p:src --hints:off --forceBuild:on \
    --nimcache:"$PROJECT_DIR/nimcache/tasks/datasets/generate_corpus" \
    -o:"$PROJECT_DIR/nimcache/datasets_generate_corpus" benchmarks/generate_corpus.nim
  "$PROJECT_DIR/nimcache/datasets_generate_corpus" "$OUTDIR"
  files+=(marker-multiblock-64m.gz marker-fallback-64m.gz bgzf-repeated.gz \
    members-10000.gz fastq-single-64m.fastq.gz fastq-concat-64m.fastq.gz \
    fastq-bgzf-32m.bgzf.fastq.gz log-lines-8m.log.gz stored-random-8m.gz)
fi

printf 'file\tsha256\tcompressed_bytes\tfastq_records\tdecoded_bytes\n' > "$WORKDIR/datasets.tsv"
for name in "${files[@]}"; do
  if command -v sha256sum >/dev/null 2>&1; then
    checksum=$(sha256sum "$OUTDIR/$name")
  else
    checksum=$(shasum -a 256 "$OUTDIR/$name")
  fi
  checksum=${checksum%% *}
  compressed_bytes=$(wc -c < "$OUTDIR/$name")
  records=NA
  decoded_bytes=NA
  if [[ -f "$WORKDIR/$name.stats" ]]; then
    read -r records decoded_bytes < "$WORKDIR/$name.stats"
  elif [[ $name == *.fastq.gz ]]; then
    inspect "$OUTDIR/$name" "$WORKDIR/$name.stats"
    read -r records decoded_bytes < "$WORKDIR/$name.stats"
  else
    decoded_bytes=$(gzip -dc -- "$OUTDIR/$name" | wc -c)
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$checksum" \
    "${compressed_bytes//[[:space:]]/}" "$records" "${decoded_bytes//[[:space:]]/}" \
    >> "$WORKDIR/datasets.tsv"
done
mv -- "$WORKDIR/datasets.tsv" "$OUTDIR/datasets.tsv"
printf 'Benchmark inputs and manifest ready in %s\n' "$OUTDIR"

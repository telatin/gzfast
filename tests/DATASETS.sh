#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTDIR=${OUTDIR:-"$SCRIPT_DIR/datasets"}
mkdir -p "$OUTDIR"
OUTDIR=$(CDPATH= cd -- "$OUTDIR" && pwd)

download() {
  printf 'Downloading %s\n' "$OUTDIR/$2"
  curl --fail --location --retry 5 --retry-delay 5 --retry-connrefused \
    --connect-timeout 30 -C - --output "$OUTDIR/$2" "$1"
}

# Illumina reads
EBI="ftp://ftp.sra.ebi.ac.uk/vol1/fastq"
download "$EBI/ERR679/005/ERR6797445/ERR6797445_1.fastq.gz" ERR6797445_R1.fastq.gz

# Nanopore
NANO_URL="https://nanopore.s3.climb.ac.uk/Zymo-GridION-EVEN-BB-SN.fq.gz"
download "$NANO_URL" nanopore.fastq.gz

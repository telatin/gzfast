NIMBLE ?= nimble

FASTQ_INPUTS ?= $(wildcard files/*.gz)
FASTQ_THREADS ?= 1,4,8
FASTQ_REPEAT ?= 3
FASTQ_WARMUP ?= 1
FASTQ_BENCH_CSV ?= fastq-bench.csv
FASTQ_SUMMARY_CSV ?= fastq-summary.csv

.PHONY: all build test bench bench-core bench-fastq clean help

all: build

build:
	$(NIMBLE) build -d:release

test:
	$(NIMBLE) test
	$(NIMBLE) testSanitize
	$(NIMBLE) fuzzSmoke
	$(NIMBLE) testPackage

bench: bench-core bench-fastq

bench-core:
	$(NIMBLE) bench

bench-fastq:
	$(NIMBLE) benchFastq
	@if [ -z "$(FASTQ_INPUTS)" ]; then \
		echo "make bench: no FASTQ gzip inputs found; skipping bench_fastq."; \
		echo "make bench: put inputs under files/*.gz or set FASTQ_INPUTS='path/*.gz'."; \
	else \
		echo "running bench_fastq on: $(FASTQ_INPUTS)"; \
		benchmarks/bench_fastq --repeat $(FASTQ_REPEAT) --warmup $(FASTQ_WARMUP) \
			--threads $(FASTQ_THREADS) $(FASTQ_INPUTS) > "$(FASTQ_BENCH_CSV)"; \
		benchmarks/bench_fastq --summary "$(FASTQ_BENCH_CSV)" > "$(FASTQ_SUMMARY_CSV)"; \
		echo "wrote $(FASTQ_BENCH_CSV)"; \
		echo "wrote $(FASTQ_SUMMARY_CSV)"; \
	fi

help:
	@echo "make              build optimized gzfast binary"
	@echo "make test         run normal, sanitizer, fuzz-smoke and package tests"
	@echo "make bench        run generated benchmarks plus FASTQ CSV and summary"
	@echo "make clean        remove local build outputs"
	@echo
	@echo "FASTQ benchmark variables:"
	@echo "  FASTQ_INPUTS='files/*.gz'"
	@echo "  FASTQ_THREADS='1,4,8'"
	@echo "  FASTQ_REPEAT=3 FASTQ_WARMUP=1"
	@echo "  FASTQ_BENCH_CSV=fastq-bench.csv"
	@echo "  FASTQ_SUMMARY_CSV=fastq-summary.csv"

clean:
	rm -f ./gzfast
	rm -f ./benchmarks/bench_fastq
	rm -f "$(FASTQ_BENCH_CSV)" "$(FASTQ_SUMMARY_CSV)"
	find . -name '*.nim' -exec sh -c 'rm -f "$${0%.nim}"' {} \;
	find . -name '*.gz' -exec sh -c 'rm -f "$${0%.gz}"' {} \;

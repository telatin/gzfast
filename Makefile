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
	rm -f ./gzfast ./gzfast_cli ./gzfast-*.tar.gz
	rm -f ./benchmarks/bench_fastq ./benchmarks/bench_decode ./benchmarks/generate_corpus
	rm -f ./examples/custom_limits ./examples/decompress_file
	rm -f ./examples/stream_fastq ./examples/verify_only
	rm -f ./fuzz/fuzz_decode ./fuzz/fuzz_header
	rm -f "$(FASTQ_BENCH_CSV)" "$(FASTQ_SUMMARY_CSV)"
	rm -rf ./nimcache ./benchmarks/generated
	find tests/unit tests/integration tests/concurrency tests/corruption \
		-maxdepth 1 -type f -name 'test_*' ! -name '*.nim' -delete
	rm -f ./tests/package/test_package
	rm -f ./tests/helpers/deflate_bits ./tests/helpers/fixtures
	rm -f ./tests/helpers/gzip_builder ./tests/helpers/run_with_timeout

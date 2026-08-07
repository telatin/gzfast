NIMBLE ?= nimble

FASTQ_INPUTS ?= $(wildcard files/*.gz)
FASTQ_THREADS ?= 1,4,8
FASTQ_MODES ?= api,cli-null,cli-file,pipe-wc
FASTQ_REPEAT ?= 3
FASTQ_WARMUP ?= 1
FASTQ_BENCH_CSV ?= fastq-bench.csv
FASTQ_SUMMARY_CSV ?= fastq-summary.csv

BENCH_INPUTS ?= $(FASTQ_INPUTS)
BENCH_THREADS ?= $(FASTQ_THREADS)
BENCH_MODES ?= $(FASTQ_MODES)
BENCH_REPEAT ?= $(FASTQ_REPEAT)
BENCH_WARMUP ?= $(FASTQ_WARMUP)
BENCH_CSV ?= $(FASTQ_BENCH_CSV)
BENCH_SUMMARY_CSV ?= $(FASTQ_SUMMARY_CSV)

.PHONY: all build test bench bench-core bench-fastq clean help

all: build

bench: build bench-core bench-fastq

build:
	$(NIMBLE) build -d:release

test:
	$(NIMBLE) test
	$(NIMBLE) testSanitize
	$(NIMBLE) fuzzSmoke
	$(NIMBLE) testPackage

bench-core:
	$(NIMBLE) bench

bench-fastq:
	$(NIMBLE) benchFastq
	@if [ -z "$(BENCH_INPUTS)" ]; then \
		echo "make bench: no gzip inputs found; skipping bench_fastq."; \
		echo "make bench: put inputs under files/*.gz or set BENCH_INPUTS='path/*.gz'."; \
	else \
		echo "running bench_fastq on: $(BENCH_INPUTS)"; \
		benchmarks/bench_fastq --repeat $(BENCH_REPEAT) --warmup $(BENCH_WARMUP) \
			--threads $(BENCH_THREADS) --modes "$(BENCH_MODES)" \
			--gzfast-bin ./gzfast $(BENCH_INPUTS) > "$(BENCH_CSV)"; \
		benchmarks/bench_fastq --summary "$(BENCH_CSV)" > "$(BENCH_SUMMARY_CSV)"; \
		echo "wrote $(BENCH_CSV)"; \
		echo "wrote $(BENCH_SUMMARY_CSV)"; \
	fi

help:
	@echo "make              build optimized gzfast binary"
	@echo "make test         run normal, sanitizer, fuzz-smoke and package tests"
	@echo "make bench        run generated benchmarks plus FASTQ CSV and summary"
	@echo "make clean        remove local build outputs"
	@echo
	@echo "Benchmark variables:"
	@echo "  BENCH_INPUTS='files/*.gz'"
	@echo "  BENCH_THREADS='1,4,8'"
	@echo "  BENCH_MODES='api,cli-null,cli-file,pipe-wc'"
	@echo "  BENCH_REPEAT=3 BENCH_WARMUP=1"
	@echo "  BENCH_CSV=fastq-bench.csv"
	@echo "  BENCH_SUMMARY_CSV=fastq-summary.csv"
	@echo "  FASTQ_* variables remain accepted as aliases."

clean:
	rm -f ./gzfast ./gzfast_cli ./gzfast-*.tar.gz
	rm -f ./benchmarks/bench_fastq ./benchmarks/bench_decode ./benchmarks/generate_corpus
	rm -f ./examples/custom_limits ./examples/decompress_file
	rm -f ./examples/stream_fastq ./examples/verify_only
	rm -f ./fuzz/fuzz_decode ./fuzz/fuzz_header
	rm -f "$(BENCH_CSV)" "$(BENCH_SUMMARY_CSV)"
	rm -rf ./nimcache ./benchmarks/generated
	find tests/unit tests/integration tests/concurrency tests/corruption \
		-maxdepth 1 -type f -name 'test_*' ! -name '*.nim' -delete
	rm -f ./tests/package/test_package
	rm -f ./tests/helpers/deflate_bits ./tests/helpers/fixtures
	rm -f ./tests/helpers/gzip_builder ./tests/helpers/run_with_timeout

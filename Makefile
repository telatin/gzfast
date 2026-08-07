NIMBLE ?= nimble

FASTQ_INPUTS ?= $(wildcard files/*.gz)
FASTQ_THREADS ?= 1,4,8
FASTQ_MODES ?= api,cli-null
FASTQ_REPEAT ?= 3
FASTQ_WARMUP ?= 1
FASTQ_BENCH_CSV ?= fastq-bench.csv
FASTQ_SUMMARY_CSV ?= fastq-summary.csv

BENCH_INPUTS ?= $(FASTQ_INPUTS)
BENCH_THREADS ?= $(FASTQ_THREADS)
BENCH_MODES ?= $(FASTQ_MODES)
BENCH_MARKER ?= 0
BENCH_REPEAT ?= $(FASTQ_REPEAT)
BENCH_WARMUP ?= $(FASTQ_WARMUP)
BENCH_CSV ?= $(FASTQ_BENCH_CSV)
BENCH_SUMMARY_CSV ?= $(FASTQ_SUMMARY_CSV)

BENCH_MARKER_FLAG = $(if $(filter 1 true yes on,$(BENCH_MARKER)),--marker,--no-marker)

EXHAUSTIVE_INPUTS ?= $(BENCH_INPUTS)
EXHAUSTIVE_THREADS ?= $(BENCH_THREADS)
EXHAUSTIVE_MODES ?= api,cli-null,cli-file,pipe-wc
EXHAUSTIVE_MARKER ?= 1
EXHAUSTIVE_REPEAT ?= $(BENCH_REPEAT)
EXHAUSTIVE_WARMUP ?= $(BENCH_WARMUP)
EXHAUSTIVE_CSV ?= fastq-bench-exhaustive.csv
EXHAUSTIVE_SUMMARY_CSV ?= fastq-summary-exhaustive.csv
EXHAUSTIVE_MARKER_FLAG = $(if $(filter 1 true yes on,$(EXHAUSTIVE_MARKER)),--marker,--no-marker)

IO_INPUTS ?= $(BENCH_INPUTS)
IO_THREADS ?= 1,4
IO_MODES ?= cli-file,pipe-wc
IO_REPEAT ?= 2
IO_WARMUP ?= 0
IO_CSV ?= fastq-bench-io.csv
IO_SUMMARY_CSV ?= fastq-summary-io.csv

CONTROL_INPUTS ?= benchmarks/generated/fastq-*.gz benchmarks/generated/bgzf-repeated.gz benchmarks/generated/members-10000.gz benchmarks/generated/log-lines-8m.log.gz benchmarks/generated/stored-random-8m.gz
CONTROL_THREADS ?= 1,4,8
CONTROL_MODES ?= api,cli-null
CONTROL_REPEAT ?= 3
CONTROL_WARMUP ?= 1
CONTROL_CSV ?= fastq-bench-controls.csv
CONTROL_SUMMARY_CSV ?= fastq-summary-controls.csv

.PHONY: all build test bench bench-core bench-fastq bench-exhaustive bench-io bench-controls clean help

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

bench-fastq: build
	$(NIMBLE) benchFastq
	@if [ -z "$(BENCH_INPUTS)" ]; then \
		echo "make bench: no gzip inputs found; skipping bench_fastq."; \
		echo "make bench: put inputs under files/*.gz or set BENCH_INPUTS='path/*.gz'."; \
	else \
		echo "running bench_fastq on: $(BENCH_INPUTS)"; \
		benchmarks/bench_fastq --repeat $(BENCH_REPEAT) --warmup $(BENCH_WARMUP) \
			--threads $(BENCH_THREADS) --modes "$(BENCH_MODES)" \
			$(BENCH_MARKER_FLAG) --gzfast-bin ./gzfast \
			$(BENCH_INPUTS) > "$(BENCH_CSV)"; \
		benchmarks/bench_fastq --summary "$(BENCH_CSV)" > "$(BENCH_SUMMARY_CSV)"; \
		echo "wrote $(BENCH_CSV)"; \
		echo "wrote $(BENCH_SUMMARY_CSV)"; \
	fi

bench-exhaustive: build bench-core
	$(NIMBLE) benchFastq
	@if [ -z "$(EXHAUSTIVE_INPUTS)" ]; then \
		echo "make bench-exhaustive: no gzip inputs found."; \
		echo "set EXHAUSTIVE_INPUTS='path/*.gz'."; \
	else \
		echo "running exhaustive bench_fastq on: $(EXHAUSTIVE_INPUTS)"; \
		benchmarks/bench_fastq --repeat $(EXHAUSTIVE_REPEAT) \
			--warmup $(EXHAUSTIVE_WARMUP) --threads $(EXHAUSTIVE_THREADS) \
			--modes "$(EXHAUSTIVE_MODES)" $(EXHAUSTIVE_MARKER_FLAG) \
			--gzfast-bin ./gzfast $(EXHAUSTIVE_INPUTS) > "$(EXHAUSTIVE_CSV)"; \
		benchmarks/bench_fastq --summary "$(EXHAUSTIVE_CSV)" > "$(EXHAUSTIVE_SUMMARY_CSV)"; \
		echo "wrote $(EXHAUSTIVE_CSV)"; \
		echo "wrote $(EXHAUSTIVE_SUMMARY_CSV)"; \
	fi

bench-io: build
	$(NIMBLE) benchFastq
	@if [ -z "$(IO_INPUTS)" ]; then \
		echo "make bench-io: no gzip inputs found."; \
		echo "set IO_INPUTS='files/large.fastq.gz files/largest.fastq.gz'."; \
	else \
		echo "running I/O bench_fastq on: $(IO_INPUTS)"; \
		benchmarks/bench_fastq --repeat $(IO_REPEAT) --warmup $(IO_WARMUP) \
			--threads $(IO_THREADS) --modes "$(IO_MODES)" --no-marker \
			--no-gunzip --no-pigz --gzfast-bin ./gzfast \
			$(IO_INPUTS) > "$(IO_CSV)"; \
		benchmarks/bench_fastq --summary "$(IO_CSV)" > "$(IO_SUMMARY_CSV)"; \
		echo "wrote $(IO_CSV)"; \
		echo "wrote $(IO_SUMMARY_CSV)"; \
	fi

bench-controls: build
	nim c -d:release --threads:on --mm:orc -p:src --hints:off \
		-o:benchmarks/generate_corpus benchmarks/generate_corpus.nim
	benchmarks/generate_corpus
	$(NIMBLE) benchFastq
	benchmarks/bench_fastq --repeat $(CONTROL_REPEAT) --warmup $(CONTROL_WARMUP) \
		--threads $(CONTROL_THREADS) --modes "$(CONTROL_MODES)" --no-marker \
		--gzfast-bin ./gzfast $(CONTROL_INPUTS) > "$(CONTROL_CSV)"
	benchmarks/bench_fastq --summary "$(CONTROL_CSV)" > "$(CONTROL_SUMMARY_CSV)"
	@echo "wrote $(CONTROL_CSV)"
	@echo "wrote $(CONTROL_SUMMARY_CSV)"

help:
	@echo "make              build optimized gzfast binary"
	@echo "make test         run normal, sanitizer, fuzz-smoke and package tests"
	@echo "make bench        run generated checks plus practical real-file benchmark"
	@echo "make bench-exhaustive"
	@echo "                  run full API/CLI/file/pipe and marker benchmark matrix"
	@echo "make bench-io     run focused CLI file-output and pipe-consumer benchmark"
	@echo "make bench-controls"
	@echo "                  run generated FASTQ-shaped and generic gzip controls"
	@echo "make clean        remove local build outputs"
	@echo
	@echo "Benchmark variables:"
	@echo "  BENCH_INPUTS='files/*.gz'"
	@echo "  BENCH_THREADS='1,4,8'"
	@echo "  BENCH_MODES='api,cli-null' BENCH_MARKER=0"
	@echo "  BENCH_REPEAT=3 BENCH_WARMUP=1"
	@echo "  BENCH_CSV=fastq-bench.csv"
	@echo "  BENCH_SUMMARY_CSV=fastq-summary.csv"
	@echo "  EXHAUSTIVE_MODES='api,cli-null,cli-file,pipe-wc' EXHAUSTIVE_MARKER=1"
	@echo "  IO_INPUTS='files/large.fastq.gz files/largest.fastq.gz'"
	@echo "  IO_THREADS='1,4' IO_MODES='cli-file,pipe-wc'"
	@echo "  CONTROL_INPUTS='benchmarks/generated/fastq-*.gz ...'"
	@echo "  FASTQ_* variables remain accepted as aliases."

clean:
	rm -f ./gzfast ./gzfast_cli ./gzfast-*.tar.gz
	rm -f ./benchmarks/bench_fastq ./benchmarks/bench_decode ./benchmarks/generate_corpus
	rm -f ./examples/custom_limits ./examples/decompress_file
	rm -f ./examples/stream_fastq ./examples/verify_only
	rm -f ./fuzz/fuzz_decode ./fuzz/fuzz_header
	rm -f "$(BENCH_CSV)" "$(BENCH_SUMMARY_CSV)"
	rm -f "$(EXHAUSTIVE_CSV)" "$(EXHAUSTIVE_SUMMARY_CSV)"
	rm -f "$(IO_CSV)" "$(IO_SUMMARY_CSV)"
	rm -f "$(CONTROL_CSV)" "$(CONTROL_SUMMARY_CSV)"
	rm -rf ./nimcache ./benchmarks/generated
	find tests/unit tests/integration tests/concurrency tests/corruption \
		-maxdepth 1 -type f -name 'test_*' ! -name '*.nim' -delete
	rm -f ./tests/package/test_package
	rm -f ./tests/helpers/deflate_bits ./tests/helpers/fixtures
	rm -f ./tests/helpers/gzip_builder ./tests/helpers/run_with_timeout

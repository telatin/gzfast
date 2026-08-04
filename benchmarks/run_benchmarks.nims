import std/os

exec "nim c -d:release --threads:on --mm:orc -p:src --hints:off " &
     "-o:benchmarks/generate_corpus benchmarks/generate_corpus.nim"
exec "benchmarks/generate_corpus"
exec "nim c -d:release --threads:on --mm:orc -p:src --hints:off " &
     "-o:benchmarks/bench_decode benchmarks/bench_decode.nim"
exec "benchmarks/bench_decode benchmarks/generated/marker-multiblock-64m.gz " &
     "benchmarks/generated/marker-fallback-64m.gz " &
     "benchmarks/generated/bgzf-repeated.gz benchmarks/generated/members-10000.gz"

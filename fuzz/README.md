# gzfast fuzz harnesses

Both harnesses are standalone, deterministic programs with bounded input
and output. They require no system zlib.

```bash
nim c --threads:on --mm:orc -p:src fuzz/fuzz_header.nim
nim c --threads:on --mm:orc -p:src fuzz/fuzz_decode.nim

./fuzz/fuzz_header tests/corpus/*.gz
./fuzz/fuzz_decode tests/corpus/*.gz
```

They can be used with process-based fuzzers such as AFL++ by passing `@@`.
Run sanitizer builds with normal bounds/overflow checks enabled; do not use
`-d:danger`. Seed with `tests/corpus/` and the corruption mutations generated
by `tests/corruption/test_matrix.nim`.

Invariants:

* no crash, defect, out-of-bounds access, or hang;
* decode output never exceeds 8 MiB;
* success means `finish()` authenticated the entire stream;
* expected malformed input is represented by a public error, not a defect.

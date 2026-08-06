# Upstream references

The gzfast design is pinned to specific upstream revisions rather than
moving branches.

## rapidgzip (C++)

* Repository: https://github.com/mxmlnkn/rapidgzip
* Commit: `d2350e9c9ba54398cd64e45bfc8c631beec017f0`
* License: MIT and Apache-2.0 (dual)
* Role: reference for the DEFLATE dynamic-block finder, the uint16
  marker/window speculative decoding scheme, marker replacement, and
  CRC combining. The principal algorithm references are
  `blockfinder/DynamicHuffman.hpp`, `chunkdecoding/GzipChunk.hpp`,
  `DecodedData.hpp`, and `MarkerReplacement.hpp`.
* No C++ code is compiled into gzfast; algorithms are re-implemented
  in Nim with attribution.

## rapidgzip-rust

* Repository: https://github.com/COMBINE-lab/rapidgzip-rust
* Commit: `72511b7b14999421a29b1449406972faa7e62137`
* License: BSD-3-Clause AND MIT
* Role: primary structural reference for the streaming-only scope:
  bounded parallel worker paths, one ordered coordinator, compressed
  grid scheduling, suffix-first window resolution, sequential fallback,
  and cancellation/backpressure behaviour.
* No Rust code is compiled into gzfast.

## zlib

* Project: https://zlib.net/
* Version: 1.3.2
* Source archive: `zlib-1.3.2.tar.gz`
* SHA-256: `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16`
* License: zlib license (see `src/vendor/zlib-1.3.2/LICENSE`)
* Role: authoritative raw-DEFLATE inflation, `inflatePrime`,
  `inflateSetDictionary`, `inflateReset`, `Z_BLOCK`, CRC32 and CRC32
  combination, compiled into the consuming application.
* Local modifications: documented in `src/vendor/README.md`
  (symbol prefixing in `zconf.h`; vendored-source subset only).

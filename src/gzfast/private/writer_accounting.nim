## Small, deterministic accounting helpers for gzip writers.

proc gzipIsize*(uncompressedBytes: uint64): uint32 {.inline.} =
  ## Gzip stores the uncompressed size modulo 2^32 in its trailer.
  uint32(uncompressedBytes and 0xffff_ffff'u64)

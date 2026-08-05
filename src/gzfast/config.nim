## Public decoder configuration.

import std/options
import ./errors

type
  GzFastConfig* = object
    ## Maximum decoder-worker budget. Zero means automatic.
    threads*: int
    ## Target decoded output chunk size.
    decodedChunkSize*: int
    ## Approximate spacing between speculative starts.
    compressedGridSize*: int
    ## Positional input page size.
    inputPageSize*: int
    ## Maximum number of completed chunks awaiting consumption.
    ## Zero means derive from the active worker budget.
    inFlightChunks*: int
    ## Maximum decoded bytes produced speculatively by one job.
    maxSpeculativeOutput*: int
    ## Optional total decoded-output limit (decompression-bomb guard).
    outputLimit*: Option[uint64]
    ## Optional approximate internal memory ceiling.
    ## Zero means derive a conservative bound from the worker budget.
    memoryLimit*: int64
    ## Permit a correct sequential fallback when parallel decoding
    ## cannot safely continue.
    allowSequentialFallback*: bool
    ## Enable the experimental rapidgzip-style marker/window path for
    ## ordinary single-member gzip files. BGZF and concatenated-member
    ## parallelism remain enabled independently of this flag.
    enableMarkerPath*: bool
    ## Maximum accepted combined size of optional gzip header fields.
    maxHeaderSize*: int

proc defaultGzFastConfig*(): GzFastConfig =
  GzFastConfig(
    threads: 0,
    decodedChunkSize: 4 * 1024 * 1024,
    compressedGridSize: 1024 * 1024,
    inputPageSize: 1024 * 1024,
    inFlightChunks: 0,
    maxSpeculativeOutput: 16 * 1024 * 1024,
    outputLimit: none(uint64),
    memoryLimit: 0,
    allowSequentialFallback: true,
    enableMarkerPath: false,
    maxHeaderSize: 1024 * 1024
  )

proc validate*(config: GzFastConfig) =
  ## Raises GzFastConfigError on invalid values.
  template fail(msg: string) =
    raise newException(GzFastConfigError, msg)
  if config.threads < 0:
    fail "threads must be >= 0 (0 means automatic)"
  if config.decodedChunkSize < 4096:
    fail "decodedChunkSize must be at least 4096 bytes"
  if config.compressedGridSize < 1024:
    fail "compressedGridSize must be at least 1024 bytes"
  if config.inputPageSize < 4096:
    fail "inputPageSize must be at least 4096 bytes"
  if config.inFlightChunks < 0:
    fail "inFlightChunks must be >= 0 (0 means automatic)"
  if config.maxSpeculativeOutput < config.decodedChunkSize:
    fail "maxSpeculativeOutput must be >= decodedChunkSize"
  if config.memoryLimit < 0:
    fail "memoryLimit must be >= 0 (0 means automatic)"
  if config.maxHeaderSize < 1024 or config.maxHeaderSize > 64 * 1024 * 1024:
    fail "maxHeaderSize must be between 1 KiB and 64 MiB"
  if config.outputLimit.isSome and config.outputLimit.get == 0:
    fail "outputLimit, when set, must be > 0"

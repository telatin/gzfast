## Public decode report and statistics.

type
  DecodePath* = enum
    dpSequential
    dpStoredBlocks
    dpBgzf
    dpMultiMember
    dpMarkerWindow
    dpMixed

  DecodeReport* = object
    ## Deterministic summary of a completed decode. Contains no timing
    ## values, so reports are comparable for equality in tests.
    compressedBytes*: uint64
    decompressedBytes*: uint64
    memberCount*: uint64
    pathsUsed*: set[DecodePath]
    crcVerified*: bool
    peakWorkers*: int
    peakBufferedBytes*: uint64

  DecoderStats* = object
    ## Approximate point-in-time snapshot; values may be slightly stale
    ## by design (lock-free counters once workers exist).
    compressedBytes*: uint64
    decompressedBytes*: uint64
    memberCount*: uint64
    activeWorkers*: int
    bufferedBytes*: uint64
    finished*: bool

  GzipWriteReport* = object
    ## Deterministic summary of a completed gzip write.
    compressedBytes*: uint64
    uncompressedBytes*: uint64
    crc32*: uint32
    isize*: uint32

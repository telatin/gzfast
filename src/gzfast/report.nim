## Public decode report and statistics.

type
  DecodePath* = enum
    dpSequential
    dpStoredBlocks
    dpBgzf
    dpMultiMember
    dpMarkerWindow
    dpMixed

  MarkerFallbackReason* = enum
    mfrNone
    mfrDecodeResultUnavailable
    mfrDecodeRejected
    mfrBoundaryMismatch
    mfrUnresolvedHistory
    mfrResolutionSubmitFailed
    mfrResolutionResultUnavailable
    mfrResolutionFailed
    mfrMarkerFreeHandoff
    mfrFollowingMember

  MarkerDiagnostics* = object
    ## Counters cover an admitted marker path, not unsuccessful open probes.
    ## Committed bytes count resolved worker output. Exact bytes count the
    ## accepted prefix/continuation; rejected speculative output is excluded.
    decodeJobs*: uint64
    committedBytes*: uint64
    exactBytes*: uint64
    bytesBeforeFallback*: uint64
    replayedBytes*: uint64 ## already committed bytes discarded during replay
    fallbackBytes*: uint64 ## fresh sequential output, excluding replay
    fallbackCompressedOffset*: uint64
    fallbackReason*: MarkerFallbackReason ## first transition out of marker work
    fallbackDetail*: string ## worker status or unresolved-history status
    exactStatus*: string ## exact continuation outcome; empty if not attempted

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
    markerDiagnostics*: MarkerDiagnostics

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

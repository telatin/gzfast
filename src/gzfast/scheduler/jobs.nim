## POD job/result messages exchanged by the bounded worker runtime.

import ../buffers

type
  JobKind* = enum
    jkDecodeBoundary
    jkResolveMarkers
    jkDecodeBgzfGroup
    jkDecodeMember
    jkDecodeStoredRange
    jkShutdown

  WorkerErrorKind* = enum
    weNone
    weCancelled
    weInvalidJob
    weAllocation
    weInvalidHeader
    weInvalidDeflate
    weTruncated
    weChecksum
    weSize
    weOutputCap
    weInternal

  ResultStatus* = enum
    jrsOk
    jrsRejected
    jrsError

  DecodeJob* = object
    ordinal*: uint64
    kind*: JobKind
    compressedStart*: uint64
    compressedEnd*: uint64
    generation*: uint32
    outputLength*: int
    payloadByte*: byte
    delayMs*: int           ## synthetic test work; zero in real jobs
    knownEnd*: uint64       ## exact member end for BGZF, zero if unknown
    authoritative*: bool    ## corruption is fatal only when authoritative
    memberIndex*: uint64
    startBit*: uint64
    stopBit*: uint64
    markerInput*: SharedBuffer
    windowInput*: SharedBuffer
    symbolCount*: int
    sourceMarkerCount*: int
    outputTracker*: ptr AllocationTracker

  WorkerErrorRecord* = object
    kind*: WorkerErrorKind
    compressedOffset*: uint64
    memberIndex*: uint64
    detailCode*: int32

  JobResult* = object
    ordinal*: uint64
    generation*: uint32
    compressedStart*: uint64
    compressedEnd*: uint64
    startBit*: uint64
    decodedLength*: uint64
    memberEnd*: uint64
    outputCrc32*: uint32
    storedCrc32*: uint32
    storedIsize*: uint32
    endBit*: uint64
    markerCount*: int
    markerStatus*: int32
    streamEnd*: bool
    handoffReady*: bool
    verifiedMembers*: int
    status*: ResultStatus
    error*: WorkerErrorRecord
    output*: SharedBuffer

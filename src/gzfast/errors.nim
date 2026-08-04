## Public error model for gzfast.

type
  GzFastErrorKind* = enum
    geInputIo
    geOutputIo
    geInvalidHeader
    geInvalidDeflate
    geTruncatedInput
    geChecksumMismatch
    geSizeMismatch
    geOutputLimit
    geCancelled
    geInternal

  GzFastError* = object of IOError
    ## Raised on the consuming thread for every unrecoverable failure.
    ## `compressedOffset` is the best known compressed-byte position of
    ## the failure; `memberIndex` identifies the gzip member (0-based).
    kind*: GzFastErrorKind
    compressedOffset*: uint64
    memberIndex*: uint64

  GzFastConfigError* = object of ValueError

proc newGzFastError*(kind: GzFastErrorKind; msg: string;
                     compressedOffset: uint64 = 0;
                     memberIndex: uint64 = 0): ref GzFastError =
  result = newException(GzFastError, msg)
  result.kind = kind
  result.compressedOffset = compressedOffset
  result.memberIndex = memberIndex

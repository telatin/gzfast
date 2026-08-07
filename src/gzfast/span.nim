## Borrowed decoded-byte spans exposed by the public streaming API.

type
  DecodedSpan* = object
    ## View of currently buffered decoded output.
    ##
    ## The pointer is owned by the reader. It remains valid only until the
    ## next operation on that reader, and callers must consume at most `len`
    ## bytes with `consumeDecoded`.
    data*: ptr UncheckedArray[byte]
    len*: int

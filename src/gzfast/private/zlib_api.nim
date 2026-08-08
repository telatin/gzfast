## Private Nim bindings over the opaque C shim (vendor/gzfast_zlib_shim.h).
##
## Everything here is internal. Public code never sees inflater handles.

import ./zlib_build

type
  GzInflaterHandle* = ptr object
    ## Opaque inflater state owned by one sequential decoder or worker.
  GzDeflaterHandle* = ptr object
    ## Opaque deflater state owned by one writer.

const
  gzNoFlush* = 0.cint
  gzSyncFlush* = 2.cint
  gzFinish* = 4.cint
  gzBlock* = 5.cint
  gzTrees* = 6.cint

  gzOk* = 0.cint
  gzStreamEnd* = 1.cint
  gzNeedDict* = 2.cint
  gzStreamError* = (-2).cint
  gzDataError* = (-3).cint
  gzMemError* = (-4).cint
  gzBufError* = (-5).cint

  gzDefaultStrategy* = 0.cint
  gzFiltered* = 1.cint
  gzHuffmanOnly* = 2.cint
  gzRle* = 3.cint
  gzFixed* = 4.cint

proc gzInflaterCreate*(): GzInflaterHandle {.
  importc: "gzfast_inflater_create", cdecl.}

proc gzInflaterDestroy*(state: GzInflaterHandle) {.
  importc: "gzfast_inflater_destroy", cdecl.}

proc gzInflaterReset*(state: GzInflaterHandle): cint {.
  importc: "gzfast_inflater_reset", cdecl.}

proc gzInflaterPrime*(state: GzInflaterHandle;
                      bitCount, bitValue: cuint): cint {.
  importc: "gzfast_inflater_prime", cdecl.}

proc gzInflaterSetDictionary*(state: GzInflaterHandle;
                              data: ptr byte; length: csize_t): cint {.
  importc: "gzfast_inflater_set_dictionary", cdecl.}

proc gzInflaterStep*(state: GzInflaterHandle;
                     input: ptr ptr byte; inputLength: ptr csize_t;
                     output: ptr ptr byte; outputLength: ptr csize_t;
                     flushMode: cint): cint {.
  importc: "gzfast_inflater_step", cdecl.}

proc gzInflaterTotalIn*(state: GzInflaterHandle): uint64 {.
  importc: "gzfast_inflater_total_in", cdecl.}

proc gzInflaterTotalOut*(state: GzInflaterHandle): uint64 {.
  importc: "gzfast_inflater_total_out", cdecl.}

proc gzInflaterDataType*(state: GzInflaterHandle): cint {.
  importc: "gzfast_inflater_data_type", cdecl.}

proc gzCrc32*(previous: uint32; data: ptr byte; length: csize_t): uint32 {.
  importc: "gzfast_crc32", cdecl.}

proc gzCrc32Combine*(first, second: uint32; secondLength: uint64): uint32 {.
  importc: "gzfast_crc32_combine", cdecl.}

proc gzZlibVersion*(): cstring {.
  importc: "gzfast_zlib_version", cdecl.}

proc gzDeflaterCreate*(level, strategy: cint): GzDeflaterHandle {.
  importc: "gzfast_deflater_create", cdecl.}

proc gzDeflaterDestroy*(state: GzDeflaterHandle) {.
  importc: "gzfast_deflater_destroy", cdecl.}

proc gzDeflaterStep*(state: GzDeflaterHandle;
                     input: ptr ptr byte; inputLength: ptr csize_t;
                     output: ptr ptr byte; outputLength: ptr csize_t;
                     flushMode: cint): cint {.
  importc: "gzfast_deflater_step", cdecl.}

proc gzDeflaterTotalIn*(state: GzDeflaterHandle): uint64 {.
  importc: "gzfast_deflater_total_in", cdecl.}

proc gzDeflaterTotalOut*(state: GzDeflaterHandle): uint64 {.
  importc: "gzfast_deflater_total_out", cdecl.}

# ---------------------------------------------------------------------------
# Small safe wrappers used by the rest of the library.

proc crc32*(data: openArray[byte]; previous: uint32 = 0): uint32 =
  ## CRC32 over a Nim buffer.
  if data.len == 0:
    return gzCrc32(previous, nil, 0)
  gzCrc32(previous, cast[ptr byte](unsafeAddr data[0]), data.len.csize_t)

proc crc32*(data: string; previous: uint32 = 0): uint32 =
  if data.len == 0:
    return gzCrc32(previous, nil, 0)
  gzCrc32(previous, cast[ptr byte](unsafeAddr data[0]), data.len.csize_t)

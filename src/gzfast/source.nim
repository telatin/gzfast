## Internal positional compressed-source abstraction.
##
## A ReadAtSource is a non-owning, thread-safe view. OwnedReadAtSource
## controls the lifetime of its platform handle or immutable test buffer.

import ./errors
import ./private/platform_io

type
  ReadAtProc* = proc(context: pointer; offset: uint64;
                     destination: pointer; length: int): int
    {.nimcall, gcsafe, raises: [].}

  CloseSourceProc = proc(context: pointer) {.nimcall, gcsafe, raises: [].}

  ReadAtSource* = object
    context*: pointer
    size*: uint64
    readAtProc*: ReadAtProc

  OwnedReadAtSource* = ref object
    ## Owner must outlive every worker using `view`.
    view*: ReadAtSource
    closeProc: CloseSourceProc
    closed: bool

  MemoryContext = object
    data: ptr UncheckedArray[byte]
    length: int

proc closePlatformContext(rawContext: pointer)
    {.nimcall, gcsafe, raises: [].} =
  if rawContext.isNil:
    return
  let context = cast[ptr PlatformFileContext](rawContext)
  closePlatformFile(context[])
  deallocShared(rawContext)

proc memoryReadAt(rawContext: pointer; offset: uint64;
                  destination: pointer; length: int): int
    {.nimcall, gcsafe, raises: [].} =
  if rawContext.isNil or length < 0:
    return -1
  let context = cast[ptr MemoryContext](rawContext)
  if offset >= uint64(context.length) or length == 0:
    return 0
  let count = min(length, context.length - int(offset))
  copyMem(destination, addr context.data[int(offset)], count)
  count

proc closeMemoryContext(rawContext: pointer)
    {.nimcall, gcsafe, raises: [].} =
  if rawContext.isNil:
    return
  let context = cast[ptr MemoryContext](rawContext)
  if not context.data.isNil:
    deallocShared(cast[pointer](context.data))
  deallocShared(rawContext)

proc openReadAtSource*(path: string): OwnedReadAtSource =
  ## Open a regular file and snapshot its compressed length.
  let rawContext = allocShared0(sizeof(PlatformFileContext))
  if rawContext.isNil:
    raise newGzFastError(geInternal, "failed to allocate source context")
  let context = cast[ptr PlatformFileContext](rawContext)
  var size: uint64
  if not openPlatformFile(path, context[], size):
    deallocShared(rawContext)
    raise newGzFastError(geInputIo, "cannot open positional input: " & path)
  OwnedReadAtSource(
    view: ReadAtSource(context: rawContext, size: size,
                       readAtProc: platformReadAt),
    closeProc: closePlatformContext
  )

proc openMemoryReadAtSource*(data: openArray[byte]): OwnedReadAtSource =
  ## Copy bytes into immutable shared storage for deterministic tests.
  let rawContext = allocShared0(sizeof(MemoryContext))
  if rawContext.isNil:
    raise newGzFastError(geInternal, "failed to allocate memory source context")
  let context = cast[ptr MemoryContext](rawContext)
  context.length = data.len
  if data.len > 0:
    context.data = cast[ptr UncheckedArray[byte]](allocShared(data.len))
    if context.data.isNil:
      deallocShared(rawContext)
      raise newGzFastError(geInternal, "failed to allocate memory source data")
    copyMem(addr context.data[0], unsafeAddr data[0], data.len)
  OwnedReadAtSource(
    view: ReadAtSource(context: rawContext, size: uint64(data.len),
                       readAtProc: memoryReadAt),
    closeProc: closeMemoryContext
  )

proc close*(owner: OwnedReadAtSource) =
  ## Close the source after all users have stopped. Idempotent.
  if not owner.isNil and not owner.closed:
    owner.closed = true
    owner.closeProc(owner.view.context)
    owner.view.context = nil

proc readAt*(source: ReadAtSource; offset: uint64; destination: pointer;
             length: int): int =
  ## Read at most `length` bytes without changing shared file position.
  if length < 0:
    raise newGzFastError(geInternal, "negative positional read length", offset)
  if length == 0 or offset >= source.size:
    return 0
  if destination.isNil:
    raise newGzFastError(geInternal, "nil positional read destination", offset)
  let available = source.size - offset
  let request = if available < uint64(length): int(available) else: length
  result = source.readAtProc(source.context, offset, destination, request)
  if result < 0:
    raise newGzFastError(geInputIo, "positional input read failed", offset)
  if result > request:
    raise newGzFastError(geInternal, "positional read exceeded request", offset)

proc readExactAt*(source: ReadAtSource; offset: uint64;
                  destination: pointer; length: int) =
  ## Loop over short reads; zero before the requested end is truncation.
  if length < 0:
    raise newGzFastError(geInternal, "negative positional read length", offset)
  if uint64(length) > source.size or offset > source.size - uint64(length):
    raise newGzFastError(geTruncatedInput,
      "positional read extends beyond snapshotted input", offset)
  var done = 0
  while done < length:
    let target = cast[pointer](cast[uint](destination) + uint(done))
    let n = source.readAt(offset + uint64(done), target, length - done)
    if n == 0:
      raise newGzFastError(geTruncatedInput,
        "premature EOF during positional read", offset + uint64(done))
    done += n

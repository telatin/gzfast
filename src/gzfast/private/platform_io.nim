## Platform-specific positional file I/O for ReadAtSource.
##
## POSIX uses pread(2), Windows uses ReadFile with an independent
## OVERLAPPED offset, and other native targets fall back to a locked
## seek/read on one file handle. All offsets are 64-bit.

when defined(js):
  {.error: "gzfast requires a native C/C++ backend".}

when defined(posix):
  import std/posix

  type PlatformFileContext* = object
    fd: cint

  proc openPlatformFile*(path: string; context: var PlatformFileContext;
                         size: var uint64): bool =
    context.fd = posix.open(path.cstring, O_RDONLY)
    if context.fd < 0:
      return false
    var st: Stat
    if fstat(context.fd, st) != 0 or st.st_size < 0:
      discard posix.close(context.fd)
      context.fd = -1
      return false
    size = uint64(st.st_size)
    true

  proc closePlatformFile*(context: var PlatformFileContext) =
    if context.fd >= 0:
      discard posix.close(context.fd)
      context.fd = -1

  proc platformReadAt*(rawContext: pointer; offset: uint64;
                       destination: pointer; length: int): int
      {.nimcall, gcsafe, raises: [].} =
    if rawContext.isNil or length < 0 or
       offset > uint64(high(Off)):
      return -1
    let context = cast[ptr PlatformFileContext](rawContext)
    if context.fd < 0:
      return -1
    pread(context.fd, destination, length, Off(offset))

elif defined(windows):
  import std/[widestrs]
  import std/winlean

  const fileAttributeNormal = 0x00000080'i32

  proc getFileSizeEx(hFile: Handle; size: ptr int64): WINBOOL
      {.stdcall, dynlib: "kernel32", importc: "GetFileSizeEx".}

  type PlatformFileContext* = object
    handle: Handle

  proc openPlatformFile*(path: string; context: var PlatformFileContext;
                         size: var uint64): bool =
    let widePath = newWideCString(path)
    context.handle = createFileW(widePath, GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING, fileAttributeNormal or FILE_FLAG_OVERLAPPED, 0)
    if context.handle == INVALID_HANDLE_VALUE:
      return false
    var signedSize: int64
    if not getFileSizeEx(context.handle, addr signedSize).isSuccess or
       signedSize < 0:
      discard closeHandle(context.handle)
      context.handle = INVALID_HANDLE_VALUE
      return false
    size = uint64(signedSize)
    true

  proc closePlatformFile*(context: var PlatformFileContext) =
    if context.handle != INVALID_HANDLE_VALUE:
      discard closeHandle(context.handle)
      context.handle = INVALID_HANDLE_VALUE

  proc platformReadAt*(rawContext: pointer; offset: uint64;
                       destination: pointer; length: int): int
      {.nimcall, gcsafe, raises: [].} =
    if rawContext.isNil or length < 0 or length > high(int32):
      return -1
    let context = cast[ptr PlatformFileContext](rawContext)
    if context.handle == INVALID_HANDLE_VALUE:
      return -1
    var overlapped: OVERLAPPED
    overlapped.offset = DWORD(offset and 0xFFFF_FFFF'u64)
    overlapped.offsetHigh = DWORD(offset shr 32)
    var bytesRead: int32
    if readFile(context.handle, destination, int32(length), addr bytesRead,
                addr overlapped).isSuccess:
      return int(bytesRead)
    let error = getLastError()
    if error == ERROR_HANDLE_EOF:
      return 0
    if error != ERROR_IO_PENDING:
      return -1
    var transferred: DWORD
    if not getOverlappedResult(context.handle, addr overlapped, transferred,
                               1.WINBOOL).isSuccess:
      return -1
    int(transferred)

else:
  import std/[locks, os]

  type PlatformFileContext* = object
    file: File
    lock: Lock
    lockReady: bool

  proc openPlatformFile*(path: string; context: var PlatformFileContext;
                         size: var uint64): bool =
    try:
      if not open(context.file, path, fmRead):
        return false
      context.lock.initLock()
      context.lockReady = true
      let signedSize = getFileSize(path)
      if signedSize < 0:
        context.file.close()
        context.lock.deinitLock()
        context.lockReady = false
        return false
      size = uint64(signedSize)
      true
    except CatchableError:
      false

  proc closePlatformFile*(context: var PlatformFileContext) =
    if not context.file.isNil:
      context.file.close()
      context.file = nil
    if context.lockReady:
      context.lock.deinitLock()
      context.lockReady = false

  proc platformReadAt*(rawContext: pointer; offset: uint64;
                       destination: pointer; length: int): int
      {.nimcall, gcsafe, raises: [].} =
    if rawContext.isNil or length < 0 or offset > uint64(high(int64)):
      return -1
    let context = cast[ptr PlatformFileContext](rawContext)
    context.lock.acquire()
    try:
      try:
        context.file.setFilePos(int64(offset))
        result = context.file.readBuffer(destination, length)
      except CatchableError:
        result = -1
    finally:
      context.lock.release()

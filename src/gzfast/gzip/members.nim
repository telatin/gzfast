## Positional gzip header parsing and bounded member-candidate scanning.

import ../source
import ../private/zlib_api
import ./header

type
  HeaderAtStatus* = enum
    hasOk
    hasInvalid
    hasTruncated
    hasTooLarge

  HeaderAtResult* = object
    status*: HeaderAtStatus
    info*: GzipHeaderInfo
    payloadOffset*: uint64
    errorOffset*: uint64

proc parseHeaderAt*(source: ReadAtSource; offset: uint64;
                    maxHeaderSize: int): HeaderAtResult =
  ## Parse one header without changing shared source state.
  if offset >= source.size:
    return HeaderAtResult(status: hasTruncated, errorOffset: offset)
  var parser = initGzipHeaderParser()
  var crc = 0'u32
  var page: array[4096, byte]
  var pagePos, pageLen: int
  var cursor = offset
  var count = 0
  while count < maxHeaderSize:
    if pagePos == pageLen:
      pageLen = source.readAt(cursor, addr page[0], page.len)
      pagePos = 0
      if pageLen == 0:
        return HeaderAtResult(status: hasTruncated, errorOffset: cursor)
    let b = page[pagePos]
    inc pagePos
    inc cursor
    inc count
    crc = crc32([b], crc)
    let fed = parser.feed(b, crc)
    case fed.kind
    of hfNeedMore:
      discard
    of hfDone:
      return HeaderAtResult(status: hasOk, info: parser.info,
                            payloadOffset: cursor)
    of hfError:
      return HeaderAtResult(status: hasInvalid, errorOffset: cursor - 1)
  HeaderAtResult(status: hasTooLarge, errorOffset: cursor)

proc scanHeaderCandidates*(source: ReadAtSource; startOffset, endOffset: uint64;
                           maxHeaderSize, maxCandidates: int): seq[uint64] =
  ## Scan a bounded compressed region for structurally valid gzip headers.
  ## Candidates are not authoritative until exact predecessor end matches.
  if maxCandidates <= 0 or startOffset >= source.size:
    return
  let stop = min(endOffset, source.size)
  var page: array[64 * 1024, byte]
  var cursor = startOffset
  var previous = 0'u8
  var havePrevious = false
  while cursor < stop and result.len < maxCandidates:
    let request = int(min(uint64(page.len), stop - cursor))
    let count = source.readAt(cursor, addr page[0], request)
    if count == 0:
      break
    for i in 0 ..< count:
      let current = page[i]
      if havePrevious and previous == 0x1F and current == 0x8B:
        let candidate = cursor + uint64(i) - 1
        let parsed = source.parseHeaderAt(candidate, maxHeaderSize)
        if parsed.status == hasOk:
          result.add(candidate)
          if result.len == maxCandidates:
            return
      previous = current
      havePrevious = true
    cursor += uint64(count)

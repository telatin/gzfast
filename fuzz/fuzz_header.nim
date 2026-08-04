## Standalone gzip-header fuzz harness. Pass one or more input files.

import std/[os]
import gzfast/source
import gzfast/gzip/[header, members]
import gzfast/private/zlib_api

proc fuzz(data: string) =
  var parser = initGzipHeaderParser()
  var crc = 0'u32
  var terminal = false
  for c in data:
    if terminal: break
    let value = byte(c)
    crc = crc32([value], crc)
    let status = parser.feed(value, crc)
    terminal = status.kind != hfNeedMore
  var bytes = newSeq[byte](data.len)
  for i, value in data: bytes[i] = byte(value)
  let owner = openMemoryReadAtSource(bytes)
  discard owner.view.parseHeaderAt(0, min(max(data.len, 1), 1024 * 1024))
  owner.close()

when isMainModule:
  if paramCount() == 0: quit("usage: fuzz_header INPUT...", 2)
  for index in 1 .. paramCount():
    let path = paramStr(index)
    let size = getFileSize(path)
    if size >= 0 and size <= 1024 * 1024:
      fuzz(readFile(path))

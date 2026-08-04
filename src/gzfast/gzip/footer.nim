## Gzip member footer (trailer): 8 bytes, little-endian CRC32 + ISIZE.

type
  GzipFooter* = object
    crc32*: uint32
    isize*: uint32

proc parseGzipFooter*(b: array[8, byte]): GzipFooter =
  GzipFooter(
    crc32: b[0].uint32 or (b[1].uint32 shl 8) or (b[2].uint32 shl 16) or
           (b[3].uint32 shl 24),
    isize: b[4].uint32 or (b[5].uint32 shl 8) or (b[6].uint32 shl 16) or
           (b[7].uint32 shl 24)
  )

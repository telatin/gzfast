## RFC 1951 constants shared by the pure-Nim DEFLATE structures.

const
  MaxCodeBits* = 15
  MaxLiteralCodes* = 286
  FixedLiteralCodes* = 288
  MaxDistanceCodes* = 32
  PrecodeSymbols* = 19
  MaxCombinedCodeLengths* = MaxLiteralCodes + MaxDistanceCodes
  EndOfBlockSymbol* = 256

  PrecodeOrder*: array[PrecodeSymbols, uint8] =
    [16'u8, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

  LengthBases*: array[29, uint16] =
    [3'u16, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
     31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LengthExtraBits*: array[29, uint8] =
    [0'u8, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
     2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

  DistanceBases*: array[30, uint16] =
    [1'u16, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
     193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
     6145, 8193, 12289, 16385, 24577]
  DistanceExtraBits*: array[30, uint8] =
    [0'u8, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
     6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

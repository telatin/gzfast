## Gzip member header parser (RFC 1952), implemented as a byte-fed
## state machine so headers split arbitrarily across input pages parse
## correctly. No allocation: optional FNAME/FCOMMENT contents are
## validated and skipped, FEXTRA subfields are validated structurally
## and scanned for the BGZF `BC` subfield.

type
  HeaderStage = enum
    hpFixed          ## bytes 0..9
    hpXlen1, hpXlen2 ## FEXTRA length, little-endian
    hpSubSi1, hpSubSi2, hpSubLen1, hpSubLen2, hpSubData
    hpFname, hpComment
    hpFhcrc1, hpFhcrc2
    hpDone

  HeaderFeedKind* = enum
    hfNeedMore  ## feed another byte
    hfDone      ## header complete and valid
    hfError     ## invalid header; msg explains

  HeaderFeedResult* = object
    case kind*: HeaderFeedKind
    of hfDone:
      discard
    of hfNeedMore:
      discard
    of hfError:
      msg*: string

  GzipHeaderParser* = object
    ## Feed bytes one at a time with `feed`. All header bytes are also
    ## checksummed incrementally so FHCRC can be verified.
    stage: HeaderStage
    byteCount: int        ## bytes fed so far
    flg: byte
    crc: uint32           ## running CRC32 of bytes before FHCRC
    fhcrc: uint16         ## accumulated FHCRC value
    fhcrcExpected: uint16 ## low 16 bits of the CRC at FHCRC start
    xlenRemaining: int    ## FEXTRA bytes left
    subSi1, subSi2: byte
    subLenRemaining: int  ## current subfield payload bytes left
    subIdBc: bool         ## current subfield is "BC"
    bsize: int            ## BGZF BSIZE+1, or 0 when no BC subfield seen

  GzipHeaderInfo* = object
    bgzfBlockSize*: int   ## BSIZE + 1 when a BC subfield was present, else 0
    headerSize*: int      ## total header bytes consumed
    hasText*: bool

const
  flgText    = 0x01.byte
  flgFhcrc   = 0x02.byte
  flgFextra  = 0x04.byte
  flgFname   = 0x08.byte
  flgFcomment = 0x10.byte
  flgReserved = 0xE0.byte

proc initGzipHeaderParser*(): GzipHeaderParser =
  GzipHeaderParser(stage: hpFixed)

proc info*(p: GzipHeaderParser): GzipHeaderInfo =
  GzipHeaderInfo(
    bgzfBlockSize: p.bsize,
    headerSize: p.byteCount,
    hasText: (p.flg and flgText) != 0
  )

proc enterFhcrc(p: var GzipHeaderParser) =
  ## Snapshot the CRC over all header bytes preceding the FHCRC field.
  p.fhcrcExpected = uint16(p.crc and 0xFFFF)
  p.stage = hpFhcrc1

proc afterFixed(p: var GzipHeaderParser) =
  if (p.flg and flgFextra) != 0: p.stage = hpXlen1
  elif (p.flg and flgFname) != 0: p.stage = hpFname
  elif (p.flg and flgFcomment) != 0: p.stage = hpComment
  elif (p.flg and flgFhcrc) != 0: p.enterFhcrc()
  else: p.stage = hpDone

proc afterExtra(p: var GzipHeaderParser) =
  if (p.flg and flgFname) != 0: p.stage = hpFname
  elif (p.flg and flgFcomment) != 0: p.stage = hpComment
  elif (p.flg and flgFhcrc) != 0: p.enterFhcrc()
  else: p.stage = hpDone

proc afterFname(p: var GzipHeaderParser) =
  if (p.flg and flgFcomment) != 0: p.stage = hpComment
  elif (p.flg and flgFhcrc) != 0: p.enterFhcrc()
  else: p.stage = hpDone

proc afterComment(p: var GzipHeaderParser) =
  if (p.flg and flgFhcrc) != 0: p.enterFhcrc()
  else: p.stage = hpDone

proc feed*(p: var GzipHeaderParser; b: byte; crcOfByte: uint32): HeaderFeedResult =
  ## Consume one header byte. `crcOfByte` must be the running CRC32
  ## *including* this byte (the caller updates it cheaply per byte).
  ## Returns hfDone when the complete valid header has been consumed.
  if p.stage == hpDone:
    return HeaderFeedResult(kind: hfError, msg: "internal: fed past header end")

  p.crc = crcOfByte
  inc p.byteCount

  template err(m: string): HeaderFeedResult =
    HeaderFeedResult(kind: hfError, msg: m)

  case p.stage
  of hpFixed:
    case p.byteCount
    of 1:
      if b != 0x1F: return err("bad gzip magic byte 1")
    of 2:
      if b != 0x8B: return err("bad gzip magic byte 2")
    of 3:
      if b != 8: return err("unsupported compression method " & $b)
    of 4:
      if (b and flgReserved) != 0:
        return err("reserved gzip header flag bits set")
      p.flg = b
    of 10:
      p.afterFixed()
    else:
      discard # MTIME(4), XFL, OS: any values accepted
  of hpXlen1:
    p.xlenRemaining = b.int
    p.stage = hpXlen2
  of hpXlen2:
    p.xlenRemaining = p.xlenRemaining or (b.int shl 8)
    if p.xlenRemaining == 0:
      p.afterExtra()
    else:
      p.stage = hpSubSi1
  of hpSubSi1:
    p.subSi1 = b
    p.stage = hpSubSi2
  of hpSubSi2:
    p.subSi2 = b
    p.stage = hpSubLen1
  of hpSubLen1:
    p.subLenRemaining = b.int
    p.stage = hpSubLen2
  of hpSubLen2:
    p.subLenRemaining = p.subLenRemaining or (b.int shl 8)
    dec p.xlenRemaining, 4
    if p.subLenRemaining > p.xlenRemaining:
      return err("malformed gzip extra field: subfield exceeds XLEN")
    p.subIdBc = p.subSi1 == 'B'.byte and p.subSi2 == 'C'.byte and
                p.subLenRemaining == 2
    dec p.xlenRemaining, p.subLenRemaining
    if p.subLenRemaining == 0:
      if p.xlenRemaining == 0: p.afterExtra()
      elif p.xlenRemaining < 4:
        return err("malformed gzip extra field: truncated subfield header")
      else: p.stage = hpSubSi1
    else:
      p.stage = hpSubData
  of hpSubData:
    if p.subIdBc:
      # BSIZE is 2 bytes little-endian; capture both.
      let idx = p.subLenRemaining # 2 then 1
      if idx == 2:
        p.bsize = b.int
      else:
        p.bsize = (p.bsize or (b.int shl 8)) + 1
    dec p.subLenRemaining
    if p.subLenRemaining == 0:
      if p.xlenRemaining == 0: p.afterExtra()
      elif p.xlenRemaining < 4:
        return err("malformed gzip extra field: truncated subfield header")
      else: p.stage = hpSubSi1
  of hpFname:
    if b == 0: p.afterFname()
  of hpComment:
    if b == 0: p.afterComment()
  of hpFhcrc1:
    p.fhcrc = b.uint16
    p.stage = hpFhcrc2
  of hpFhcrc2:
    p.fhcrc = p.fhcrc or (b.uint16 shl 8)
    if p.fhcrc != p.fhcrcExpected:
      return err("gzip header CRC mismatch")
    p.stage = hpDone
  of hpDone:
    discard

  if p.stage == hpDone:
    HeaderFeedResult(kind: hfDone)
  else:
    HeaderFeedResult(kind: hfNeedMore)

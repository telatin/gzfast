## Differential structural checks against the bundled zlib inflater.

import std/unittest
import gzfast/source
import gzfast/gzip/members
import gzfast/deflate/[bitreader, block_header, dynamic_header]
import gzfast/private/zlib_api
import ../helpers/fixtures

proc zlibHeaderEnd(raw: string): uint64 =
  let inflater = gzInflaterCreate()
  check not inflater.isNil
  defer: gzInflaterDestroy(inflater)
  var output = newString(4096)
  var inputPtr = cast[ptr byte](unsafeAddr raw[0])
  var inputLength = csize_t(raw.len)
  var outputPtr = cast[ptr byte](addr output[0])
  var outputLength = csize_t(output.len)
  let status = gzInflaterStep(inflater, addr inputPtr, addr inputLength,
    addr outputPtr, addr outputLength, gzTrees)
  check status == gzOk or status == gzStreamEnd
  let dataType = int(gzInflaterDataType(inflater))
  check (dataType and 256) != 0
  gzInflaterTotalIn(inflater) * 8 - uint64(dataType and 0x3F)

suite "DEFLATE structures versus bundled zlib":
  test "dynamic header end bit agrees with Z_TREES":
    let raw = readFixture("raw_deflate.bin")
    let owner = openMemoryReadAtSource(toBytes(raw))
    defer: owner.close()
    var reader = initBitReader(owner.view)
    var blockHeader: DeflateBlockHeader
    check reader.tryReadBlockHeader(blockHeader)
    check blockHeader.blockType == dbtDynamic
    let workspace = newDynamicHeaderWorkspace()
    var info: DynamicHeaderInfo
    check reader.parseDynamicHeader(workspace, info) == dhsOk
    check info.headerEndBit == zlibHeaderEnd(raw)

  test "corpus first blocks classify as fixed and stored":
    for (name, expected) in [("fixed_huffman.gz", dbtFixed),
                             ("stored.gz", dbtStored)]:
      let owner = openReadAtSource(fixturePath(name))
      defer: owner.close()
      let header = owner.view.parseHeaderAt(0, 1024 * 1024)
      check header.status == hasOk
      var reader = initBitReader(owner.view, header.payloadOffset * 8)
      var blockHeader: DeflateBlockHeader
      check reader.tryReadBlockHeader(blockHeader)
      check blockHeader.blockType == expected

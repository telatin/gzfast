## Shared helpers for gzfast tests: corpus manifest access.

import std/[os, strutils]

type
  Fixture* = object
    name*: string
    length*: uint64
    crc32*: uint32
    members*: int
    expect*: string
    sha256*: string

proc corpusDir*(): string =
  currentSourcePath().parentDir().parentDir() / "corpus"

proc fixtures*(): seq[Fixture] =
  for line in lines(corpusDir() / "MANIFEST.txt"):
    var f: Fixture
    for kv in line.split(' '):
      let p = kv.split('=', 1)
      case p[0]
      of "name": f.name = p[1]
      of "length": f.length = parseUint(p[1])
      of "crc32": f.crc32 = uint32(parseHexInt(p[1]))
      of "members": f.members = parseInt(p[1])
      of "expect": f.expect = p[1]
      of "sha256": f.sha256 = p[1]
      else: discard
    result.add(f)

proc fixturePath*(name: string): string =
  corpusDir() / name

proc fixtureByName*(name: string): Fixture =
  for f in fixtures():
    if f.name == name:
      return f
  raise newException(ValueError, "unknown fixture: " & name)

proc readFixture*(name: string): string =
  readFile(fixturePath(name))

proc toBytes*(s: string): seq[byte] =
  result = newSeqOfCap[byte](s.len)
  for c in s:
    result.add c.byte

proc toString*(b: openArray[byte]): string =
  result = newString(b.len)
  for i, c in b:
    result[i] = char(c)

## Bounded candidate planning for concatenated ordinary gzip members.

import ../source
import ../gzip/members
import ../scheduler/jobs

proc planMemberBatch*(source: ReadAtSource; authoritativeStart: uint64;
                      scanEnd: uint64; maxHeaderSize,
                      maxCandidates: int;
                      firstOrdinal: uint64): seq[DecodeJob] =
  let candidates = source.scanHeaderCandidates(authoritativeStart, scanEnd,
    maxHeaderSize, maxCandidates)
  for index, offset in candidates:
    result.add DecodeJob(
      ordinal: firstOrdinal + uint64(index),
      kind: jkDecodeMember,
      compressedStart: offset,
      authoritative: offset == authoritativeStart,
      memberIndex: firstOrdinal + uint64(index)
    )

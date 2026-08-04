## BGZF path planning helpers. Independent block decoding is performed
## by member workers; this module validates/schedules one exact link.

import ../source
import ../gzip/bgzf
import ../scheduler/jobs

proc planBgzfJob*(source: ReadAtSource; offset, ordinal: uint64;
                  maxHeaderSize: int): tuple[status: BgzfLinkStatus,
                                              job: DecodeJob] =
  let link = source.inspectBgzfLink(offset, maxHeaderSize)
  result.status = link.status
  if link.status == blsOk:
    result.job = DecodeJob(
      ordinal: ordinal,
      kind: jkDecodeBgzfGroup,
      compressedStart: link.startOffset,
      compressedEnd: link.endOffset,
      knownEnd: link.endOffset,
      authoritative: true,
      memberIndex: ordinal
    )

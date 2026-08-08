## gzfast — fast, verified gzip I/O for Nim.
##
## This module is the entire public import surface:
##
## ```nim
## import gzfast
##
## let input = openGzFast("reads.fastq.gz", threads = 8)
## defer: input.close()
## for line in input.lines:
##   discard line
## discard input.finish()
##
## let output = openGzFastWriter("out.gz")
## discard output.writeString("hello\n")
## output.close()
## ```
##
## Guarantees:
## * No system zlib (or any other non-Nim library) is required; the
##   bundled zlib 1.3.2 is compiled into your application.
## * Bounded streaming memory, independent of file size.
## * Reading to EOF (or calling `finish`) verifies every member's
##   CRC32 and ISIZE, including concatenated members.
## * Gzip writing emits a standard header, raw-DEFLATE payload, and
##   CRC32/ISIZE trailer.
## * The stream is forward-only; seeking is unsupported.

import std/options
import std/streams

import ./gzfast/config
import ./gzfast/errors
import ./gzfast/report
import ./gzfast/span
import ./gzfast/reader
import ./gzfast/decoder
import ./gzfast/writer

export streams
export options.none, options.some, options.Option

export GzFastConfig, GzFastWriteConfig
export defaultGzFastConfig, defaultGzFastWriteConfig, validate
export GzFastError, GzFastErrorKind, GzFastConfigError
export DecodePath, DecodeReport, DecoderStats, GzipWriteReport
export DecodedSpan
export GzFastStream, finish, cancel, stats, peekDecoded, consumeDecoded
export GzFastWriter
export GzFastDecoder, initGzFastDecoder
export open, openGzFast, openGzFastSequential
export decodeTo, decompressFile
export openGzFastWriter, writeData, writeString, writeBytes, writeLine
export flush, close

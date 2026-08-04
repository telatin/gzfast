## gzfast — fast, verified, multithreaded gzip decompression for Nim.
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
## ```
##
## Guarantees:
## * No system zlib (or any other non-Nim library) is required; the
##   bundled zlib 1.3.2 is compiled into your application.
## * Bounded streaming memory, independent of file size.
## * Reading to EOF (or calling `finish`) verifies every member's
##   CRC32 and ISIZE, including concatenated members.
## * The stream is forward-only; seeking is unsupported.

import std/options
import std/streams

import ./gzfast/config
import ./gzfast/errors
import ./gzfast/report
import ./gzfast/reader
import ./gzfast/decoder

export streams
export options.none, options.some, options.Option

export GzFastConfig, defaultGzFastConfig, validate
export GzFastError, GzFastErrorKind, GzFastConfigError
export DecodePath, DecodeReport, DecoderStats
export GzFastStream, finish, cancel, stats
export GzFastDecoder, initGzFastDecoder
export open, openGzFast, openGzFastSequential
export decodeTo, decompressFile

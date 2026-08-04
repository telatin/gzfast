## Private build integration for the vendored zlib 1.3.2.
##
## This is the *only* module that references the vendored C sources.
## It compiles them into the consuming application via `{.compile.}`;
## there is deliberately no `{.passL: "-lz".}` and no `dynlib`
## anywhere in the project (see src/vendor/README.md).
##
## The vendor tree lives under src/ (not the repository root) because
## nimble installs the contents of srcDir at the package root; keeping
## the C sources inside srcDir makes the relative paths below resolve
## identically in the development checkout and in an installed package.

import std/os

const vendorDir = currentSourcePath().parentDir() / ".." / ".." / "vendor"
const zlibDir = vendorDir / "zlib-1.3.2"

# Production inflate subset (see vendor/README.md). The deflate-side
# sources are compiled only by tests/helpers for fixture generation.
{.compile: zlibDir / "adler32.c".}
{.compile: zlibDir / "crc32.c".}
{.compile: zlibDir / "inffast.c".}
{.compile: zlibDir / "inflate.c".}
{.compile: zlibDir / "inftrees.c".}
{.compile: zlibDir / "zutil.c".}
{.compile: vendorDir / "gzfast_zlib_shim.c".}

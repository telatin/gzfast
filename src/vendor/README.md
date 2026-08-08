# Vendored third-party sources for gzfast

This directory (src/vendor inside the repository, installed as `vendor` in
the Nimble package) is bundled inside the gzfast Nimble package so that a
consuming Nim program needs **no system compression library**: the C
sources below are compiled directly into the final executable through
Nim's `{.compile.}` mechanism. There is no `-lz`, no `dynlib`, no
`pkg-config`, no CMake, no configure step at install time.

## Contents

* `zlib-1.3.2/` — source subset of the official zlib 1.3.2 release
  (`zlib-1.3.2.tar.gz`, SHA-256
  `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16`).
  All top-level C sources and headers are kept. The production library
  compiles the raw inflate/deflate subset used by the shim:
  `adler32.c crc32.c deflate.c inffast.c inflate.c inftrees.c trees.c
  zutil.c`. The gzip file API sources such as `gzread.c`, `gzwrite.c`,
  and `gzlib.c` are kept for source completeness but are not compiled by
  gzfast.
  Platform/build files from the tarball (`win32/`, `contrib/`,
  `CMakeLists.txt`, `configure`, …) are intentionally not vendored.
* `gzfast_zlib_shim.h` / `gzfast_zlib_shim.c` — the only interface Nim
  code uses. Opaque handle, integer status codes, raw-DEFLATE mode.
* `README.md` — this file.

## Local modifications

1. **`zlib-1.3.2/zconf.h`: symbol prefixing.** A clearly marked block at
   the end of `zconf.h` (search for `GZFAST_Z_PREFIX_INCLUDED`) renames
   every externally linked zlib symbol with the `gzfast_z_` prefix, e.g.
   `inflate` → `gzfast_z_inflate`, `crc32` → `gzfast_z_crc32`. The block
   was generated from the actual `nm` symbol tables of the vendored
   objects, and CI verifies that the built binaries contain no
   unprefixed zlib globals and no `libz`/`zlib1.dll` dependency. This
   prevents duplicate-symbol conflicts when a consuming application also
   links another zlib copy. The `gzgetc` function-like macro in `zlib.h`
   is excluded from renaming.

2. **Vendored subset only.** As described above, only top-level sources
   are kept; no zlib build system is shipped and no zlib configuration
   script is ever run during `nimble install`.

No other changes were made to the upstream sources. The zlib licence
(`zlib-1.3.2/LICENSE`, also in `zlib.h`) permits this redistribution;
the notice is retained. See `UPSTREAM.md` and `THIRD_PARTY_NOTICES.md` at the repository root.

Note: the vendor tree lives under `src/` rather than the repository root
because nimble installs the contents of `srcDir` at the package root.
Placing the C sources inside `srcDir` makes the relative `{.compile.}`
paths resolve identically in the development checkout and in an
installed package.

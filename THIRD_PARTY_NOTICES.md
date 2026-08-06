# Third-party notices

gzfast vendors or derives from the following projects. Their licenses
are retained and reproduced here or alongside the relevant sources.

## zlib 1.3.2 (zlib license)

Bundled at `src/vendor/zlib-1.3.2/`, locally modified only by the
symbol-prefixing block in `zconf.h` (see `src/vendor/README.md`).
The full license text is in `src/vendor/zlib-1.3.2/LICENSE` and in
`zlib.h`:

> Copyright (C) 1995-2024 Jean-loup Gailly and Mark Adler
>
> This software is provided 'as-is', without any express or implied
> warranty. In no event will the authors be held liable for any damages
> arising from the use of this software.
>
> Permission is granted to anyone to use this software for any purpose,
> including commercial applications, and to alter it and redistribute it
> freely, subject to the following restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not
>    claim that you wrote the original software. If you use this software
>    in a product, an acknowledgment in the product documentation would be
>    appreciated but is not required.
> 2. Altered source versions must be plainly marked as such, and must not be
>    misrepresented as being the original software.
> 3. This notice may not be removed or altered from any source distribution.
>
> Jean-loup Gailly        Mark Adler
> jloup@gzip.org          madler@alumni.caltech.edu

## rapidgzip (MIT / Apache-2.0)

Algorithmic reference (DEFLATE block finding, marker/window scheme,
marker replacement, CRC combining). Copyright (c) the rapidgzip
authors (Maximilian Knespel and contributors). Licenses:
`LICENSE-MIT` and `LICENSE-APACHE` in the upstream repository
https://github.com/mxmlnkn/rapidgzip.

## rapidgzip-rust (BSD-3-Clause AND MIT)

Architectural reference (bounded streaming coordinator, scheduling,
fallback model). Copyright (c) the rapidgzip-rust authors
(COMBINE-lab and contributors). Licenses: `LICENSE-BSD-3-CLAUSE` and
`LICENSE-MIT` in the upstream repository
https://github.com/COMBINE-lab/rapidgzip-rust.

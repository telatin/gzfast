/*
 * gzfast_zlib_shim.h
 *
 * Stable opaque C ABI between gzfast (Nim) and the privately vendored,
 * symbol-prefixed copy of zlib 1.3.2 (see vendor/README.md).
 *
 * Design goals:
 *   - Never expose z_stream or zlib macros to Nim.
 *   - Integer status codes only; no C strings, no exceptions.
 *   - No global mutable inflater state; each handle is independent and
 *     may be owned by one worker thread at a time.
 *   - Raw DEFLATE mode only; gzip framing is handled in Nim code.
 *
 * All functions are thread-safe with respect to *distinct* handles.
 * A single handle must not be used concurrently from multiple threads.
 */

#ifndef GZFAST_ZLIB_SHIM_H
#define GZFAST_ZLIB_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#  ifdef GZFAST_SHIM_BUILD_DLL
#    define GZFAST_SHIM_API __declspec(dllexport)
#  else
#    define GZFAST_SHIM_API
#  endif
#else
#  define GZFAST_SHIM_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gzfast_inflater gzfast_inflater;

/* Flush modes accepted by gzfast_inflater_step (mirrors zlib). */
#define GZFAST_Z_NO_FLUSH      0
#define GZFAST_Z_PARTIAL_FLUSH 1
#define GZFAST_Z_SYNC_FLUSH    2
#define GZFAST_Z_FULL_FLUSH    3
#define GZFAST_Z_FINISH        4
#define GZFAST_Z_BLOCK         5
#define GZFAST_Z_TREES         6

/* Status codes returned by shim functions (mirrors zlib). */
#define GZFAST_Z_OK            0
#define GZFAST_Z_STREAM_END    1
#define GZFAST_Z_NEED_DICT     2
#define GZFAST_Z_ERRNO        (-1)
#define GZFAST_Z_STREAM_ERROR (-2)
#define GZFAST_Z_DATA_ERROR   (-3)
#define GZFAST_Z_MEM_ERROR    (-4)
#define GZFAST_Z_BUF_ERROR    (-5)
#define GZFAST_Z_VERSION_ERROR (-6)

/* Create an inflater in raw-DEFLATE mode (negative window bits).
 * Returns NULL on allocation failure. */
GZFAST_SHIM_API gzfast_inflater* gzfast_inflater_create(void);

/* Destroy an inflater. Safe to call with NULL. */
GZFAST_SHIM_API void gzfast_inflater_destroy(gzfast_inflater* state);

/* Full reset: discard all state including any dictionary and history. */
GZFAST_SHIM_API int gzfast_inflater_reset(gzfast_inflater* state);

/* Prime the bit buffer with `bit_count` (0..16) bits taken from the
 * low bits of `bit_value`, for starting inflation at a non-byte-aligned
 * bit offset. Must be called immediately after a reset. */
GZFAST_SHIM_API int gzfast_inflater_prime(
    gzfast_inflater* state,
    unsigned bit_count,
    unsigned bit_value
);

/* Install a 32 KiB (or shorter) history window as the inflate dictionary. */
GZFAST_SHIM_API int gzfast_inflater_set_dictionary(
    gzfast_inflater* state,
    const unsigned char* data,
    size_t length
);

/* Perform one inflate step.
 *
 * On entry, *input / *input_length describe the available compressed
 * bytes and *output / *output_length the available destination space.
 * On return the pointers and lengths are advanced past the consumed
 * input and produced output. `flush_mode` is one of GZFAST_Z_* above.
 *
 * Returns a GZFAST_Z_* status code. */
GZFAST_SHIM_API int gzfast_inflater_step(
    gzfast_inflater* state,
    const unsigned char** input,
    size_t* input_length,
    unsigned char** output,
    size_t* output_length,
    int flush_mode
);

GZFAST_SHIM_API uint64_t gzfast_inflater_total_in(
    const gzfast_inflater* state
);

GZFAST_SHIM_API uint64_t gzfast_inflater_total_out(
    const gzfast_inflater* state
);

/* Raw zlib data_type field: low six bits are unused input bits, bit 6
 * marks the final block, bit 7 a block boundary, and bit 8 completion
 * of a block header under Z_TREES. */
GZFAST_SHIM_API int gzfast_inflater_data_type(
    const gzfast_inflater* state
);

/* CRC32 (gzip polynomial) over `length` bytes, continuing `previous`. */
GZFAST_SHIM_API uint32_t gzfast_crc32(
    uint32_t previous,
    const unsigned char* data,
    size_t length
);

/* Combine two CRC32 values as if computed over concatenated data,
 * where the second segment had `second_length` bytes. */
GZFAST_SHIM_API uint32_t gzfast_crc32_combine(
    uint32_t first,
    uint32_t second,
    uint64_t second_length
);

/* Version of the vendored zlib, for diagnostics. */
GZFAST_SHIM_API const char* gzfast_zlib_version(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GZFAST_ZLIB_SHIM_H */

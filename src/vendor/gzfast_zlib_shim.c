/*
 * gzfast_zlib_shim.c
 *
 * Implementation of the opaque gzfast inflater ABI on top of the
 * vendored, symbol-prefixed zlib 1.3.2 (vendor/zlib-1.3.2).
 *
 * The vendored zconf.h renames every zlib symbol to gzfast_z_*;
 * the calls below are rewritten by those macros automatically.
 */

#include "gzfast_zlib_shim.h"
#include "zlib-1.3.2/zlib.h"

#include <stdlib.h>
#include <string.h>

struct gzfast_inflater {
    z_stream strm;
};

/* Clamp a size_t to zlib's uInt (the vendored zlib uses 32-bit uInt). */
static uInt gzfast_clamp_uInt(size_t n) {
    return n > (size_t)0xFFFFFFFFu ? 0xFFFFFFFFu : (uInt)n;
}

gzfast_inflater* gzfast_inflater_create(void) {
    gzfast_inflater* s = (gzfast_inflater*)calloc(1, sizeof(gzfast_inflater));
    int ret;
    if (s == NULL) {
        return NULL;
    }
    s->strm.zalloc = Z_NULL;
    s->strm.zfree = Z_NULL;
    s->strm.opaque = Z_NULL;
    /* Negative window bits: raw DEFLATE, no zlib/gzip wrapper. */
    ret = inflateInit2_(&s->strm, -MAX_WBITS, ZLIB_VERSION,
                        (int)sizeof(z_stream));
    if (ret != Z_OK) {
        free(s);
        return NULL;
    }
    return s;
}

void gzfast_inflater_destroy(gzfast_inflater* state) {
    if (state == NULL) {
        return;
    }
    (void)inflateEnd(&state->strm);
    free(state);
}

int gzfast_inflater_reset(gzfast_inflater* state) {
    if (state == NULL) {
        return GZFAST_Z_STREAM_ERROR;
    }
    return inflateReset(&state->strm);
}

int gzfast_inflater_prime(gzfast_inflater* state,
                          unsigned bit_count,
                          unsigned bit_value) {
    if (state == NULL) {
        return GZFAST_Z_STREAM_ERROR;
    }
    if (bit_count > 16u) {
        return GZFAST_Z_STREAM_ERROR;
    }
    return inflatePrime(&state->strm, (int)bit_count, (int)bit_value);
}

int gzfast_inflater_set_dictionary(gzfast_inflater* state,
                                   const unsigned char* data,
                                   size_t length) {
    if (state == NULL || (data == NULL && length != 0u)) {
        return GZFAST_Z_STREAM_ERROR;
    }
    return inflateSetDictionary(&state->strm, data, gzfast_clamp_uInt(length));
}

int gzfast_inflater_step(gzfast_inflater* state,
                         const unsigned char** input,
                         size_t* input_length,
                         unsigned char** output,
                         size_t* output_length,
                         int flush_mode) {
    uInt in_before;
    uInt out_before;
    int ret;

    if (state == NULL || input == NULL || input_length == NULL ||
        output == NULL || output_length == NULL) {
        return GZFAST_Z_STREAM_ERROR;
    }

    state->strm.next_in = (Bytef*)*input;
    in_before = gzfast_clamp_uInt(*input_length);
    state->strm.avail_in = in_before;
    state->strm.next_out = (Bytef*)*output;
    out_before = gzfast_clamp_uInt(*output_length);
    state->strm.avail_out = out_before;

    ret = inflate(&state->strm, flush_mode);

    *input += (size_t)(in_before - state->strm.avail_in);
    *input_length -= (size_t)(in_before - state->strm.avail_in);
    *output += (size_t)(out_before - state->strm.avail_out);
    *output_length -= (size_t)(out_before - state->strm.avail_out);

    return ret;
}

uint64_t gzfast_inflater_total_in(const gzfast_inflater* state) {
    if (state == NULL) {
        return 0;
    }
    return (uint64_t)state->strm.total_in;
}

uint64_t gzfast_inflater_total_out(const gzfast_inflater* state) {
    if (state == NULL) {
        return 0;
    }
    return (uint64_t)state->strm.total_out;
}

int gzfast_inflater_data_type(const gzfast_inflater* state) {
    if (state == NULL) {
        return -1;
    }
    return state->strm.data_type;
}

uint32_t gzfast_crc32(uint32_t previous,
                      const unsigned char* data,
                      size_t length) {
    uLong crc = (uLong)previous;
    /* Feed in uInt-sized pieces; the loop is never hot because callers
     * pass bounded chunks, but keep it correct for any length. */
    while (length != 0u) {
        uInt piece = gzfast_clamp_uInt(length);
        crc = crc32(crc, data, piece);
        if (data != NULL) {
            data += piece;
        }
        length -= (size_t)piece;
    }
    return (uint32_t)crc;
}

uint32_t gzfast_crc32_combine(uint32_t first,
                              uint32_t second,
                              uint64_t second_length) {
    /* crc32_combine64 is exported by the vendored crc32.c; it is not
     * declared in zlib.h, so declare it here. The vendored zconf.h
     * macro-renames it to gzfast_z_crc32_combine64. */
    extern uLong crc32_combine64(uLong crc1, uLong crc2, z_off64_t len2);
    return (uint32_t)crc32_combine64((uLong)first, (uLong)second,
                                     (z_off64_t)second_length);
}

const char* gzfast_zlib_version(void) {
    return zlibVersion();
}

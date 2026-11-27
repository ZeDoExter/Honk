/* honk_gzip_shim.c -- one-shot gzip (RFC 1952) via system zlib.
 *
 * Goose `extern fn` cannot grow a builder by pointer, so this shim deflates
 * into a malloc'd scratch (compressBound-sized) and appends once into the
 * caller's Goose builder via honk_rref.h — same single-copy discipline as
 * hsql_col_text. One malloc/free per compressed response; apps that never
 * import honk_gzip link neither this TU nor -lz.
 */

#include "honk_rref.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

#pragma pack(push, 1)
typedef struct {
    uint8_t *data;
    int64_t len;
} sl_u8_gzip;
#pragma pack(pop)

#define HGZ_MAX_SRC (8 << 20)

/* Deflate src once into out as a gzip member (zlib level 6). Returns the
 * compressed byte count, or -1 (caller falls back to identity). */
int64_t hgz_deflate(sl_u8_gzip src, gs_rref out) {
    if (!src.data || src.len < 0 || src.len > HGZ_MAX_SRC) return -1;
    uLong bound = compressBound((uLong)src.len);
    uint8_t *tmp = (uint8_t *)malloc(bound > 0 ? (size_t)bound : 1);
    if (!tmp) return -1;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        free(tmp);
        return -1;
    }
    zs.next_in = (Bytef *)src.data;
    zs.avail_in = (uInt)src.len;
    zs.next_out = tmp;
    zs.avail_out = (uInt)bound;
    int64_t ret = -1;
    if (deflate(&zs, Z_FINISH) == Z_STREAM_END) {
        int64_t have = (int64_t)zs.total_out;
        if (have > 0) honk_rref_append(out, tmp, have);
        ret = have;
    }
    deflateEnd(&zs);
    free(tmp);
    return ret;
}

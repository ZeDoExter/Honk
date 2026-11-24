#include "goose.h"
#include <stdint.h>
#include <string.h>

#pragma pack(push, 1)
typedef struct {
    int32_t off_g;
    int32_t len_g;
} Span_g;
#pragma pack(pop)

static __thread int tls_calls = 0;

int32_t shim_fill_direct(gs_rref out, Span_g *out_span) {
    tls_calls++;
    const char *raw = "GET /hello from gs_rref";
    int64_t n = 23;
    /* Direct write into out.stk->top, simulating recv(fd, out.stk->top, ...) */
    memcpy(out.stk->top, raw, (size_t)n);
    out.stk->top += n;
    out.hdr->len += n;
    out_span->off_g = 5;
    out_span->len_g = 18;
    return (int32_t)n;
}

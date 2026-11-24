/* honk_rref.h -- SINGLE point of access to Goose gs_rref / gs_rhdr / gs_stack
 * in the Honk C shim (Requirement E: Stack Discipline Isolation).
 *
 * Pinned to Goose compiler commit: 2239b92eb2ae0e8f390f98640b09ff57a17698fc
 * (v2026.4-78-g2239b92e, runtime hash 68cc5acec0ef).
 *
 * No other C file in src/shim/ may touch gs_rref.hdr, gs_rref.stk,
 * gs_rhdr.base, gs_rhdr.len, or gs_stack.top directly.
 */

#ifndef HONK_RREF_H
#define HONK_RREF_H

#include "goose.h"
#include <assert.h>
#include <stddef.h>
#include <stdint.h>

/* Compile-time layout assertions against goose.h (64-bit Linux x86_64 target).
 * Fails compilation immediately if Goose changes gs_stack, gs_rhdr, or gs_rref. */
_Static_assert(sizeof(void *) == 8, "Honk requires a 64-bit target");
_Static_assert(sizeof(gs_stack) == 8, "gs_stack size changed from 8 bytes");
_Static_assert(offsetof(gs_stack, top) == 0, "gs_stack.top offset changed from 0");

_Static_assert(sizeof(gs_rhdr) == 16, "gs_rhdr size changed from 16 bytes");
_Static_assert(offsetof(gs_rhdr, base) == 0, "gs_rhdr.base offset changed from 0");
_Static_assert(offsetof(gs_rhdr, len) == 8, "gs_rhdr.len offset changed from 8");

_Static_assert(sizeof(gs_rref) == 16, "gs_rref size changed from 16 bytes");
_Static_assert(offsetof(gs_rref, hdr) == 0, "gs_rref.hdr offset changed from 0");
_Static_assert(offsetof(gs_rref, stk) == 8, "gs_rref.stk offset changed from 8");

/* Invariant: while a u8[>..] builder is active on top of its data stack,
 * stk->top MUST equal hdr->base + hdr->len. */
static inline int honk_rref_invariant_ok(gs_rref r) {
    return (r.hdr != NULL) && (r.stk != NULL) && (r.hdr->len >= 0) &&
           (r.stk->top == r.hdr->base + r.hdr->len);
}

/* Returns the raw address of stk->top for stack-discipline verification tests. */
static inline int64_t honk_rref_top_addr(gs_rref r) {
    assert(honk_rref_invariant_ok(r));
    return (int64_t)(uintptr_t)r.stk->top;
}

/* Returns the raw address of hdr->base (the baseline stack top for this scope). */
static inline int64_t honk_rref_base_addr(gs_rref r) {
    assert(honk_rref_invariant_ok(r));
    return (int64_t)(uintptr_t)r.hdr->base;
}

static inline int64_t honk_rref_len(gs_rref r) {
    assert(honk_rref_invariant_ok(r));
    return r.hdr->len;
}

static inline uint8_t *honk_rref_data(gs_rref r) {
    assert(honk_rref_invariant_ok(r));
    return r.hdr->base;
}

/* Pointer to the current top of the data stack where new bytes can be read directly. */
static inline uint8_t *honk_rref_write_ptr(gs_rref r) {
    assert(honk_rref_invariant_ok(r));
    return r.stk->top;
}

/* Append n bytes from src onto the builder using goose.h's gs_bld_append. */
static inline void honk_rref_append(gs_rref r, const void *src, int64_t n) {
    assert(honk_rref_invariant_ok(r));
    if (n > 0) {
        gs_bld_append(r, src, n);
    }
    assert(honk_rref_invariant_ok(r));
}

/* Commit n > 0 bytes written directly at honk_rref_write_ptr(r). */
static inline void honk_rref_commit(gs_rref r, int64_t n) {
    assert(honk_rref_invariant_ok(r));
    if (n > 0) {
        r.stk->top += n;
        r.hdr->len += n;
    }
    assert(honk_rref_invariant_ok(r));
}

/* Roll back / reset the builder to empty, restoring stk->top to hdr->base.
 * MUST be called on every early-exit / error path that touched r, and at turn exit. */
static inline void honk_rref_reset(gs_rref r) {
    assert(r.hdr != NULL && r.stk != NULL);
    r.stk->top = r.hdr->base;
    r.hdr->len = 0;
    assert(honk_rref_invariant_ok(r));
}

#endif /* HONK_RREF_H */

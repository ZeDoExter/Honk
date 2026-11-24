# Goose Compiler Issues & Workarounds (`docs/goose-issues.md`)

This document tracks any Goose compiler or runtime issues encountered while building Honk, along with minimal reproductions and workarounds.

## Observed During Phase 0 (Compiler Build Warnings Only)
No compiler bugs hit yet during Phase 0. The following compiler warnings were observed when building `goose` (`v2026.4-78-g2239b92e`) from source:
- **GCC 13.3.0 (`src/typecheck.h:870:21`)**: `-Wmaybe-uninitialized` on `int64_t v;` when inlined into `TypeCheck::MayHoldBuilt`.
- **GCC 13.3.0 (`src/runtime/runtime_impl.h:635:1`)**: `'noreturn' function does return` warning on `gs_end` when compiled under `GS_HOSTED_JIT` in `src/jit_runtime.c`.
- **MSVC 19.44 (`src/runtime/runtime_threads.h:211:1`)**: `C4701: potentially uninitialized local variable 'contain' used` in `gs_thread_main` (guarded by `t->contained`).

## Phase 2 (Framework Layer) — No Compiler Bugs
All `goose check` errors hit during Phase 2 were legitimate diagnostics, fixed in our code (no workarounds, no repros to file):
- `match` is a reserved keyword (renamed a local to `same`).
- Trailing comma after `..` in a struct literal is rejected (removed the comma).
- UFCS resolves struct fields before functions: `c.query(k)` hit field `query`, so the field was renamed to `query_str` (function keeps the nice name).
- Borrow §9.2: `read_string` views root at the caller's `r.text`, so a callee-owned `Reader`'s strings cannot be returned; restructured to caller-owned `Reader` + out-struct (`parse_typed_fields(r, scratch, t)`), and struct fields (not `var` re-binding) for mixed-root slices. Design verified by probes `build/probe*_phase2.goose` (since removed) and the passing suite.
`goose check`, `goose check --bce-lines`, `goose build`, and `goose -o --standalone` all behaved correctly throughout.

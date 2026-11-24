# Goose Compiler Issues & Workarounds (`docs/goose-issues.md`)

This document tracks any Goose compiler or runtime issues encountered while building Honk, along with minimal reproductions and workarounds.

## Observed During Phase 0 (Compiler Build Warnings Only)
No compiler bugs hit yet during Phase 0. The following compiler warnings were observed when building `goose` (`v2026.4-78-g2239b92e`) from source:
- **GCC 13.3.0 (`src/typecheck.h:870:21`)**: `-Wmaybe-uninitialized` on `int64_t v;` when inlined into `TypeCheck::MayHoldBuilt`.
- **GCC 13.3.0 (`src/runtime/runtime_impl.h:635:1`)**: `'noreturn' function does return` warning on `gs_end` when compiled under `GS_HOSTED_JIT` in `src/jit_runtime.c`.
- **MSVC 19.44 (`src/runtime/runtime_threads.h:211:1`)**: `C4701: potentially uninitialized local variable 'contain' used` in `gs_thread_main` (guarded by `t->contained`).

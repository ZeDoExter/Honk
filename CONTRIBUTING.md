# Contributing to Honk

This page is for **framework contributors** (the `src/honk_*` packages, the C
shim, and the test/bench harness). Application developers: you will never need
any of this — see [`QUICKSTART.md`](QUICKSTART.md) instead.

## Architecture invariants (do not break)

1. **Stack discipline is the memory model.** Each live `u8[>..]`/`Node[>..]`
   builder owns one data stack; `stk->top` must equal `hdr->base + hdr->len`
   whenever a builder crosses into C, and every scope exit resets tops. All
   `gs_rref`/`gs_rhdr`/`gs_stack` touchpoints live in **one file only**:
   `src/shim/honk_rref.h` (with `_Static_assert` layout checks against the
   pinned Goose commit). No other C file may touch `hdr`/`stk`/`top`.
2. **Thread-local everything.** Workers share nothing: all shim state is
   `static __thread`, all Goose worker state is per-`thread_fn`. No locks, no
   globals-with-writers. `thread_fn` workers must always be built with
   `goose build` (never JIT).
3. **Candidate (iii) buffers.** Fast path = `recv()` straight into the turn's
   `rx_buf` top; only unparsed tails spill to lazy per-connection C buffers;
   only unsent bytes queue in `pending_tx`. Caps: 4096 conns/worker, 8 KiB
   headers (431), 1 MiB bodies (413), 1 MiB pending-tx, no chunked requests
   (501). Any proposal needing a shim/buffer change must present options
   **before** touching `src/shim/`.
4. **Borrow §9.2 shapes the JSON API.** `read_string` views root at the
   caller's `r.text`: readers stay caller-owned, results accumulate in struct
   fields (never `var` re-binding across roots). See `D-006.5`.
5. **Blocks are inlined — value semantics.** A block parameter bound from a
   struct *value* is a copy; staging/mutations need a `&` crossing (the
   `request_run` forward in `honk_serve`). Never `return`/`break` inside a
   block (it exits the enclosing function/loop); use `if`/`else`. `thread_fn`
   must be top-level and cannot be generic or passed as a value.
6. **Pinned toolchain.** Goose `2239b92e` (`v2026.4-78-g2239b92e`, runtime
   `68cc5acec0ef`), GCC 13.3, WSL2 Ubuntu 24.04. Don't upgrade casually:
   `honk_rref.h` asserts will fail the build if layouts drift.

## Package layout

- `src/honk_net/` — transport externs + `RawReq` (Goose side of the shim).
- `src/honk_ctx/` — `Ctx`, request views, staging helpers, `emit`.
- `src/honk_json/` — demo typed bindings + serializers (apps copy the pattern).
- `src/honk_router/` — demo dispatch (middleware + routes for `src/server.goose`).
- `src/honk_serve/` — `honk::` runner (`listen`, `serve`, `request` blocks).
- `src/shim/` — `honk_shim.c`, `honk_rref.h`, vendored `picohttpparser.*`.
- `src/server_minimal.goose` — transport-only demo (transport suite target).
- `src/server.goose` — full demo + bench mode (`argv[5]=1`) for shootouts.

Goose rule that shapes this: a root file cannot import two modules from one
directory, and there is no re-export — hence one directory per package, roots
declare packages (`import honk_net from "./honk_net";`), libraries reference
them bare (`import honk_net;`).

## Verification (run all of it)

```sh
./honk test     # builds everything; 900k turns; transport + framework + web
                # suites on Release AND ASan+UBSan+LSan (must exit 0, 0 findings)
```

Manual equivalents (what CI runs):

```sh
./goose_repo/build-linux/goose build src/server.goose -o src/server
./goose_repo/build-linux/goose -o /tmp/s.c --standalone src/server.goose
gcc -O2 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Isrc/shim -Igoose_repo/src/runtime /tmp/s.c src/shim/honk_shim.c \
  src/shim/picohttpparser.c -o src/server_asan -lm -pthread -ldl
./test/test_stack_discipline                                  # 900,000 turns
python3 test/test_transport.py ./src/server_minimal
python3 test/test_framework.py ./src/server 18210 Release
python3 test/test_framework.py ./src/server_asan 18310 ASan
python3 test/test_web.py ./test/helpers_app 18420 Release
python3 test/test_web.py ./test/helpers_app_asan 18421 ASan
python3 bench/check_regression.py    # no-perf-regression gate vs Bare-C
```

ASan binaries must exit `0` via `honk_worker_shutdown()` (route-triggered
`honk_request_stop()`) so LSan runs; suites fail on any sanitizer token in
stderr. Never commit `/tmp` artifacts; `build/` is gitignored scratch.

## PR checklist

- [ ] `goose check` clean (zero warnings) on every touched root.
- [ ] `./honk test` green (Release + ASan, all suites, `0` findings).
- [ ] New hot-path code: `goose check --bce-lines` reviewed (untrusted-span
      checks stay; no new kept checks on `/plaintext`-shaped routes) and
      generated C spot-checked (dispatch still inlined, per-request tops reset).
- [ ] No `honk_rref.h` / buffer-design change without a written options review.
- [ ] User-facing change? Update `README.md` + `docs/API.md` (+ `GUIDE.md` recipe).
- [ ] Bench-affecting change? Note WSL2-indicative numbers + rerun command.

## Reports & decisions (history, keep navigable)

`docs/DECISIONS.md` (D-001…), `docs/goose-issues.md`,
`docs/{phase0-report,step1a-spike-report,step1b-report,phase2-report,phase3-report}.md`.
When renaming files, sweep every reference (docs + code + `.build` + CI).

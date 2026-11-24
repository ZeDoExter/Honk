# Phase 5 Report — Toolchain Setup, `sendfile` Static, SQLite, Full-Stack, v0.1.0

> **Single-Core Pinned (`taskset -c 0`) — WSL2 Indicative.** Same box/protocol
> as Phase 3 (i5-10300H, `wrk -t2 -c64 -d5s` on CPUs `4,6`). Re-run:
> `python3 bench/bench_phase5_perf.py` (+ `./honk test` for all suites).

## 1. Executive Summary

- **`./honk setup`**: fresh-clone bootstrap (clone → pin `2239b92e` → cmake build
  → `doctor`); idempotent fast path verified. CI and `Dockerfile` both delegate
  to it; both install `libsqlite3-dev`.
- **`sendfile` static serving** (`src/honk_static/` + shim): MIME table, `HEAD`,
  `index.html`/SPA fallback, traversal/symlink/FIFO hardening, non-blocking
  `EAGAIN`+`EPOLLOUT` resume, fd closed exactly once. `honk_rref.h` untouched.
- **Opt-in SQLite** (`src/honk_sqlite/` + `src/shim/honk_sqlite_shim.c`): per-worker
  WAL connections, prepared statements, single-copy column readers. Non-SQLite
  binaries provably link no `libsqlite3` (`ldd`) and keep their size.
- **Full-stack Todo** (`examples/fullstack_todo/`): one binary serves the UI via
  `sendfile` and `GET/POST/PATCH/DELETE /api/todos` via SQLite.
- **Verification**: `./honk test` ALL GREEN (11 gates incl. new 10-test Phase 5
  suite on Release + ASan+UBSan+LSan, fd counts stable); W1 ratio vs Bare-C
  `89.2%` (no regression); static `26.2k req/s` @256 KiB (`~6.7 GB/s`); SQLite
  point lookup `79.5k req/s`; RSS flat (`2.0–3.6 MB`).
- **Anything not done**: none. Tag `v0.1.0` created (all gates green).

## 2. Workstream 1 — Polish & `./honk setup`

- `README.md`: standard `docker build/run` commands; capabilities rewritten
  (serve API, CLI, CORS/cookies/decoding/wildcards, `sendfile`, SQLite, Docker,
  CI); "Not yet" shrunk to TLS / HTTP/2+ / chunked bodies / WebSockets.
- `./honk setup` (`honk.py`): verifies pinned goose (`2239b92e…`) else clones,
  checks out, `cmake -B build-linux` + `cmake --build` (`-jN`), then `doctor`.
  Refuses Windows-native with WSL2 guidance. Idempotent (fast path <4 s here).
- `Dockerfile`: builder delegates to `./honk setup` (single pin source) +
  `libsqlite3-dev`; runtime stays `debian:13-slim` (glibc 2.41 ≥ builder's 2.38).
- `.github/workflows/ci.yml`: rewritten (prior version had a broken apt block);
  now installs toolchain + `libsqlite3-dev`, runs `./honk setup`, then
  `./honk test` (extended below with Phase 5 gates).

## 3. Workstream 2 — Static Files (`sendfile`)

### Design (`D-010`)
- `honk::request` sends **per request** (fresh `tx` scope each iteration) instead
  of batching: static headers go out via `honk_send` (queued behind pending
  bytes), then file bytes via `honk_sendfile_data`. Ordering is always correct
  under pipelining; `wrk` never pipelines (verified 1:1), so batching bought
  nothing measurable. (Phase 1's `process_ready_fd` keeps batching untouched.)
- Shim: `sendfile_fd/off/remain` per conn; `sendfile_push` (1 MiB chunks/turn);
  `flush_pending_tx` drains headers first, then resumes file bytes; close is
  deferred while a transfer is active; every `open` is closed exactly once
  (completion/error/timeout/`shutdown`). At most one active transfer per conn
  (a pipelined second file under backpressure closes cleanly — documented).
- `honk_static.try_serve_file` (Goose): method gate (`405`), `%`-decode,
  segment validation (`..`/NUL/backslash rejected, `.`/empties skipped),
  `index.html` fallback, `O_NOFOLLOW`+`O_NONBLOCK`+`S_ISREG` open, MIME table
  (14 types + octet-stream), `HEAD`/empty via the normal path with explicit
  `Content-Length`, headers byte-identical in order to `emit()`.
- `serve_rel` powers SPA fallback (`GET /*` → `index.html`).

### Bugs found by tests (all fixed)
- Pipelined static stalled: first design broke the turn and stashed *complete*
  requests in `partial_rx` (no future `EPOLLIN` ever comes) → rewrote to
  per-request sends (above).
- FIFO open blocked the worker → added `O_NONBLOCK` (fstat still rejects).

## 4. Workstream 3 — SQLite (`D-011`, opt-in)

- `src/honk_sqlite.goose` + `src/shim/honk_sqlite_shim.c` (slice/errno
  translation; `u64` handles; `honk_rref.h` reused for builder appends —
  no new rref touchpoints). Linked only when the app's `.build` lists the
  shim + `c_libs = ["sqlite3"]`; `./honk build --asan` mirrors this by
  scanning for the import. `./honk` auto-exports `CPATH`/`LIBRARY_PATH`
  for a `~/.local/sqlite3` user-space install (no-sudo fallback).
- One `NOMUTEX` connection + prepared statements per worker, captured by
  request blocks (worker-state pattern, see `GUIDE.md`); DDL once in `main`
  (concurrent DDL can abort with `SQLITE_SCHEMA`, which `busy_timeout` does
  not cover); `busy_timeout` set before WAL setup.
- `bind_text` = `TRANSIENT` (safe); `bind_text_static` documented-unsafe;
  `col_text` appends once into request scope (FFI cannot alias foreign
  pointers, so one copy is the floor — zero heap Strings either way).
- Shutdown: `finalize` → `close` per worker, `db_shutdown()` in `main` after
  join → LSan fully clean (verified, incl. 2-worker WAL hammering).
- Honest note: `col_text` is "single copy", not literally zero-copy (Goose
  borrow rules forbid aliasing SQLite-owned buffers); slices live for the
  whole request scope, which is stronger than the row lifetime requested.

## 5. Workstream 4 — Full-Stack Todo + Phase 5 Suite

- `examples/fullstack_todo/`: `public/{index.html,app.js,style.css}` via
  `sendfile` + `GET/POST/PATCH/DELETE /api/todos` via SQLite (WAL + 4 prepared
  statements) + SPA fallback + README. Works under `./honk dev` and
  `./honk build --release` (171 KiB + system `libsqlite3`).
- `test/test_phase5_fullstack.py` (10 tests, Release + ASan): exact-byte
  static (small + MIME + `HEAD` + index + pipeline), 2 MiB `EAGAIN` resume
  (small rcvbuf, hash-verified), 14-case security matrix (traversal,
  `%`-tricks, NUL, backslash, symlink escape, FIFO, missing, `405`),
  full CRUD, strict `400`s, UTF-8/emoji + SQL-injection literals stored
  verbatim, malformed-JSON stmt discipline, 8-thread × 25-op 2-worker WAL
  hammering (CPUs 0+2, exit 0), fd-count stability, fullstack E2E (also on
  the ASan binary in ASan mode). Fixtures live in `test/static_fixtures/`;
  big/symlink/fifo/DB files generate per-run in `mkdtemp` (the repo may sit
  on a 9P mount without FIFOs or SQLite locking).

## 6. Verification Gates

### 6.1 `./honk test` — ALL GREEN (11 gates)

| Gate | Result |
|---|---|
| build (all Release incl. phase5 + fullstack) | **PASS** |
| stack discipline 900,000 turns | **PASS** |
| transport 9/9 (Release) | **PASS** |
| framework 10/10 (Release) | **PASS** |
| web 7/7 (Release) | **PASS** |
| build (ASan server + helpers + phase5 + fullstack) | **PASS** |
| framework 10/10 (ASan+UBSan+LSan, exit 0) | **PASS**, 0 findings |
| web 7/7 (ASan+UBSan+LSan, exit 0) | **PASS**, 0 findings |
| **phase5 10/10 (Release)** | **PASS** |
| **phase5 10/10 (ASan+UBSan+LSan, exit 0)** | **PASS**, 0 findings, fds stable |

### 6.2 Perf Baseline (`bench/bench_phase5_perf.py`, 5 rounds)

| Workload | Median `req/s` (min–max) | Total | User | Sys |
|---|---:|---:|---:|---:|
| W1 Bare-C | `148,929` (`126,662`–`158,004`) | `6.762` | `0.421` | `6.234` |
| W1 Honk | `132,781` (`121,047`–`138,120`) | `7.470` | `0.573` | `6.982` |
| Static 256 KiB (sendfile) | `26,168` (`25,373`–`27,273`) | `39.795` | `1.758` | `38.061` |
| SQLite point lookup | `79,531` (`64,260`–`85,590`) | `12.564` | `3.037` | `9.677` |

- **W1 non-regression**: Honk/C ratio **`89.2%`** (Phase 3: `89.4%`), user delta
  `+152 ns` (Phase 3: `+115 ns`, WSL2 noise). Absolute numbers move with
  machine state; ratios hold. An OLD-vs-NEW A/B on the same state confirmed
  the serve refactor is performance-neutral (NEW marginally ahead).
- **Static**: `26.2k × 256 KiB ≈ 6.7 GB/s` single-core; user-space `1.8 µs/req`
  (the rest is kernel TCP — exactly where `sendfile` should bill).
- **SQLite**: `79.5k req/s` prepared point lookups at `3.0 µs` user.

### 6.3 Memory & Footprint

| Binary | Size | `libsqlite3` (ldd) |
|---|---:|---|
| quickstart (no SQLite) | `143.9 KiB` | **no** |
| server demo (no SQLite) | `172.4 KiB` | **no** |
| fullstack (SQLite) | `167.0 KiB` | yes (system `.so.0`) |

`VmRSS` after load: Honk `2,048 kB`, static app `3,712 kB`, db app `3,712 kB`
(HWM identical — flat, no growth; `+1.6 MB` on SQLite apps is the library).

## 7. Notes & Follow-Ups

- Adversarial tiny-window (`4 KiB` rcvbuf) bulk throughput is receiver/TCP-
  dynamics bound (~100 ms round-trips on this WSL2 box, all servers equally);
  the suite uses realistic-but-forcing 32 KiB windows (still dozens of
  `EPOLLOUT` resumes per transfer, byte-verified).
- Multi-worker WAL needs a POSIX filesystem (9P mounts can't back `-shm`);
  single-connection SQLite works anywhere (proven on 9P).
- `kiri` host port-forwarding is broken environment-wide here (stock `nginx`
  image equally unreachable); the `honk:quickstart` image (29.9 MB) was
  verified serving from inside the container instead.
- `/tmp` does not persist across separate `wsl -e` calls in this setup; the
  harness/tests keep cross-call artifacts under repo-ignored `build/`.

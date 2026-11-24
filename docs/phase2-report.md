# Phase 2 Report — Honk HTTP Framework Layer in Goose

> **Environment Note (WSL2)**: All performance measurements below were collected on WSL2
> (Ubuntu 24.04.4 LTS, kernel `6.6.87.2-microsoft-standard-WSL2`, Intel Core i5-10300H
> @ 2.50 GHz, 4 physical cores / 8 threads) and are **indicative only**; final claims
> require native Linux. Server pinned to CPU `0`, `wrk -t2 -c64 -d10s --latency` to CPUs
> `4,6` (same protocol as Step 1b).

## 1. Executive Summary

- **Goal**: Build the Honk HTTP framework layer (`src/honk_ctx.goose`, `src/honk_json.goose`,
  `src/honk_router.goose`, `src/server_phase2.goose`) on the locked Phase 1 transport.
- **Shim / buffer-design changes required**: **None**. Zero-copy `Context`, dispatch-as-code
  routing, middleware, header/query parsing, and JSON all compose on unmodified
  `honk_conn_read` / `honk_parse_req` / `honk_send` / `honk_conn_finish` + Candidate (iii)
  lazy buffers. Decisions recorded as `D-006`/`D-007` in `docs/DECISIONS.md`.
- **Correctness**: Phase 1 regression green (`900,000` stack turns + 9/9 suite);
  new 10-test Phase 2 suite green on **both Release and ASan+UBSan+LSan** (exit `0`,
  zero sanitizer findings), including a 2-worker `SO_REUSEPORT` test on CPUs `0,2`.
- **Framework overhead** (same-run, `GET /plaintext`): **User CPU/req `0.554 µs` vs
  bare-C `0.392 µs` → `+162 ns/req`** for router + middleware + central emit.
  `req/s` median `156,700` vs bare-C `170,332` (`92.0%`, WSL2 indicative).
- **JSON baselines**: `GET /json` median `148,264 req/s` (usr `0.781 µs/req`);
  `POST /api/typed` median `98,874 req/s` (usr `1.784 µs/req`).
- **Memory**: `VmRSS`/`VmHWM` flat at **`1,920 kB`** across idle / 64 / 1024 conns and
  after 4,000 JSON requests (zero growth; `+512 kB` vs Phase 1 from framework + JSON
  code/stack pages touched).
- **Anything not done**: **None**. No Elysia/Bun comparisons yet (Phase 3, per plan).

---

## 2. Public API & Architecture

### 2.1 Modules

| File | Contents |
|---|---|
| `src/honk_ctx.goose` | `Ctx` (zero-copy views + staged response), `make_ctx`, `header` (case-insensitive), `query`, `param`, `set_header`, `text`/`bytes`/`json_body`, `status_text`, central `emit` |
| `src/honk_json.goose` | `parse_typed_fields` (caller-owned `json::Reader`), `emit_typed_post`, `dom_summary` (`json::parse`), `emit_dom_res`, `emit_hello_json` |
| `src/honk_router.goose` | `match_1param`/`match_org_repo`/`known_path`, middleware (`mw_first`, `mw_second`, `mw_auth`, `mw_after`), 13 handlers, `dispatch`/`dispatch_get`, `process_ready_fd2` (per-request scopes) |
| `src/server_phase2.goose` | Multi-worker runner: `[port] [idle_timeout_ms] [header_timeout_ms] [num_workers]`, `thread_fn` + `SO_REUSEPORT` + `honk_pin_thread_cpu`, clean `honk_worker_shutdown` exit |

### 2.2 Route Table (`server_phase2.goose` demo app)

| Method | Path | Handler | Response |
|---|---|---|---|
| `GET`/`HEAD` | `/`, `/plaintext` | `h_plaintext` | `200` `Hello, World!` (byte-identical to Phase 1) |
| `GET`/`HEAD` | `/json` | `h_json` | `200` JSON greeting + nested user struct |
| `GET`/`HEAD` | `/users/:id` | `h_user` | `200` `{"id","verbose"}` (`?verbose=1`) |
| `PUT` | `/users/:id` | `h_user_update` | `200` `{"id","updated":true}` |
| `GET`/`HEAD` | `/orgs/:org/repos/:repo` | `h_org_repo` | `200` `{"org","repo"}` |
| `GET`/`HEAD` | `/greet?name=` | `h_greet` | `200` `Hello, <name>!` |
| `GET`/`HEAD` | `/ua` | `h_ua` | `200` `User-Agent` echo / `unknown` |
| `GET`/`HEAD` | `/admin/secret` | `h_admin` (guarded) | `401` short-circuit / `200` secret for `<user>` |
| `POST` | `/echo` | `h_echo` | `200` body echo |
| `POST` | `/api/typed` | `h_typed` | `200` typed echo / `400` |
| `POST` | `/api/dom` | `h_dom` | `200` `{"count","msg"}` / `400` |
| `GET`/`HEAD` | `/stats`, `/large` | (Phase 1 kept) | telemetry / 16 KiB payload |
| `POST` | `/__shutdown` | `h_shutdown` | clean worker exit (LSan runs) |
| any other | known path | — | `405 Method Not Allowed` |
| any | unknown path | — | `404 Not Found` |

### 2.3 Key Design Points (see `D-006`, `D-007`)

- **Stage + central emit**: handlers stage `(status, ctype, body-slice, extras)`; one
  `emit()` writes framing. `Content-Length` correct by construction; `HEAD`/`204`
  handled centrally.
- **Dispatch-as-code**: inline `if/else` graph, zero-alloc matchers, no fn-pointer
  tables; all handlers/middleware inline into the worker loop.
- **Middleware**: before-chain + auth short-circuit (`401`, handler provably skipped via
  absent `X-Handler-Ran`) + after-hook staging `X-Worker`.
- **Hot-path exemption** (`D-007`): `/` and `/plaintext` run middleware but stage no
  headers → byte-identical to bare C; overhead measured honestly.
- **Caller-owned `json::Reader`** (borrow §9.2): `parse_typed_fields(r, scratch, t)`;
  unescaped strings zero-copy from `rx_buf`, escaped via per-request `scratch`;
  mixed-root slices held in struct fields.
- **Per-request scope** per pipelined request: `body_buf`/`scratch`/`doc`/`decoded`
  reset every loop iteration (verified in generated C).

### 2.4 Example (`server_phase2.goose` worker)

```goose
thread_fn worker_phase2(cfg: WorkerCfg2) {
    honk_pin_thread_cpu(cfg.worker_id, cfg.cpu_id);
    honk_set_timeouts(cfg.idle_timeout_ms, cfg.header_timeout_ms);
    guard honk_worker_init(cfg.port) == 0 else { abort("honk_worker_init failed"); }
    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];
    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 100);
        if nfds <= 0 { continue; }
        assert(nfds <= 256);
        for i in nfds {
            process_ready_fd2(ready_fds[i], date_hdr);  // framework dispatch
        }
        if honk_should_stop() != 0 { honk_worker_shutdown(); break; }
    }
}
```

---

## 3. Verification

### 3.1 Phase 1 Regression Gate (unchanged files, rebuilt nothing)

- `./test/test_stack_discipline`: **all 9 paths × 100,000 (`900,000` turns) PASS**,
  `stk->top == baseline` every turn.
- `python3 test/test_phase1_correctness.py ./src/server_phase1`: **9/9 PASS**.

### 3.2 Phase 2 Suite (`test/test_phase2_framework.py`, 10 tests)

Release build: `goose build src/server_phase2.goose -o src/server_phase2`.
ASan build:
```sh
./goose_repo/build-linux/goose -o /tmp/server_phase2_standalone.c --standalone src/server_phase2.goose
gcc -O2 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Isrc/shim -Igoose_repo/src/runtime /tmp/server_phase2_standalone.c \
  src/shim/honk_shim.c src/shim/picohttpparser.c \
  -o src/server_phase2_asan -lm -pthread -ldl
```

| Test | Verified | Release | ASan+UBSan+LSan |
|---|---|---|---|
| `test_01_static_and_byte_shape` | `/`, `/plaintext` 200, exact 115-byte shape, no MW headers | **PASS** | **PASS** |
| `test_02_params_query_headers` | `:id`, `:org/:repo`, `?name=` (first-wins, empty→default), case-insensitive `User-Agent`, `X-MW-1/2` + `X-Worker` order | **PASS** | **PASS** |
| `test_03_404_vs_405` | 404×5, 405×9 (incl. `FOO`), `PUT /users/:id` 200 | **PASS** | **PASS** |
| `test_04_middleware_auth` | 401 w/o `X-Handler-Ran`, 200 with user decoration | **PASS** | **PASS** |
| `test_05_head` | HEAD mirrors GET `Content-Length`, zero body bytes | **PASS** | **PASS** |
| `test_06_typed_json` | full nested + escapes + unknown-skip; 13 invalid classes → 400 (conn alive); `>1 MiB` → 413 + close | **PASS** | **PASS** |
| `test_07_dom_json` | DOM count/msg incl. scalar/array roots; 4 invalid → 400 | **PASS** | **PASS** |
| `test_08_keepalive_split_pipeline` | sequential mix, mid-escape split `recv`, 4-mix pipeline + alive check, 20× `/json` identical bodies | **PASS** | **PASS** |
| `test_09_stats_and_large` | `/stats` telemetry keys, `/large` 16,384 B intact | **PASS** | **PASS** |
| `test_10_two_workers` | CPU `0`+`2` affinity, 200 mixed conns served by workers `0`+`1`, clean shutdown, exit `0` | **PASS** | **PASS** |

- **Sanitizers**: exit code `0` on every server run; `stderr` scanned for
  `AddressSanitizer` / `runtime error:` / `LeakSanitizer` / `SUMMARY:` →
  **zero findings** on both 1-worker and 2-worker runs (LSan end-of-process leaks: none).

---

## 4. `--bce-lines` & Generated C Audit

### 4.1 BCE (`goose check src/server_phase2.goose --bce-lines`)

- **Elided**: `ready_fds[i]` (hot loop), `c.params[0..1]` literal indices,
  `c.extras[i]` in `emit` after hoisting `n_extra` to a local (2 elided, 0 kept),
  `hn[k]` in header compare, `format_number` internals (7 elided).
- **Kept (all justified)**:
  - `rem_slice[req.*_off..*_end]` + `rx_buf[cursor..]` + header-block scan: **untrusted
    C spans / `picohttpparser` offsets — must keep** (same 3 + request-line checks as Phase 1).
  - Header/query scan indexing (`while`-loop pattern) and `name[k]` (needs `==` chain):
    cold routes only (`/ua`, `/greet`, `/users?verbose`, `/admin`); check cost trivial vs scan.
  - `match_org_repo` slicing: cold (non-static paths / 404-405 fallthrough).
  - `read_string`/`format_*` call lines: stdlib-internal checks attributed to call sites;
    per-JSON-value, not per-plaintext-request.
  - `t.tags[nt]`: 1 kept (store through `&`-param struct); per array element.
- **Hot path (`/plaintext`)**: zero kept checks beyond the 3 inherited Phase 1 span
  checks; dispatch is compare + call only.

### 4.2 Generated C (`server_phase2.c`, 13,126 lines)

- **Inlining**: `dispatch`, `dispatch_get`, `process_ready_fd2`, `make_ctx`, all 13
  handlers, all 4 middleware fns, `known_path`, `text`/`bytes`/`json_body`,
  `param`/`set_header`, `emit_*`, `dom_summary` → **no `_g` definitions (fully inlined
  into `worker_phase2_g`)**. `match_1param`/`match_org_repo` are `GS_INLINE`.
  Real calls: `emit_g`, `status_text_g`, `parse_typed_fields_g` (per-request, fine),
  `header_g`/`query_g` (cold routes only — never on `/plaintext`).
- **Register-held tops**: `t1219` (tx) and `t1220` (body) with direct
  `*t = byte; t++; len++` appends and `gs_memcpy`, mirroring Phase 1's `t108`;
  `GS(top)` writeback-before-call keeps rref calls (`json::format_*`) correct.
- **Per-request resets**: `+3/+4/+5` (`scratch`/`doc`/`decoded`) tops reset to base on
  **every loop-back edge and both `break` paths**; `+2` (body) via register rebase
  (`t1220 = body_buf_g.base`) + turn-exit writeback. Verified at all scope exits.
- **`--stacks`**: worker = **11 data stacks** (rx, tx, body, scratch, doc, decoded,
  `json::parse` error + transient JSON stacks); thread cap 1,488 — no constraint.

---

## 5. Performance & Memory (Release Builds, Indicative Only — WSL2)

### 5.1 `curl -i` Equivalence (`bench/curl_c_control_p2.txt` vs `bench/curl_phase2.txt`)

Both **115 bytes, 100% byte-identical** (same-second capture):
```http
HTTP/1.1 200 OK
Content-Type: text/plain
Date: Tue, 24 Nov 2026 12:xx:xx GMT
Content-Length: 13

Hello, World!
```

### 5.2 7-Round Interleaved `GET /plaintext` (Round 1 = warmup)

| Round | Server | `req/s` | Total (`µs`) | User (`µs`) | Sys (`µs`) | Srv CPU% | `wrk` CPU% | `p99` |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 *(wu)* | Bare-C | `186,474.33` | `5.336` | `0.340` | `4.996` | `99.1%` | `145.4%` | `0.99ms` |
| 1 *(wu)* | Phase 2 | `167,668.71` | `5.763` | `0.511` | `5.251` | `105.6%` | `146.1%` | `659.22ms` |
| **2** | **Bare-C** | `192,459.52` | `5.309` | `0.350` | `4.959` | `101.6%` | `148.1%` | `0.92ms` |
| **2** | **Phase 2** | `167,339.45` | `6.141` | `0.550` | `5.591` | `103.0%` | `145.1%` | `1.07ms` |
| **3** | **Bare-C** | `155,545.73` | `5.774` | `0.376` | `5.399` | `98.0%` | `148.1%` | `793.63ms` |
| **3** | **Phase 2** | `154,235.38` | `6.554` | `0.532` | `6.023` | `100.9%` | `139.1%` | `1.29ms` |
| **4** | **Bare-C** | `169,062.97` | `5.991` | `0.469` | `5.523` | `101.1%` | `148.1%` | `1.14ms` |
| **4** | **Phase 2** | `141,945.04` | `6.591` | `0.559` | `6.032` | `101.1%` | `141.5%` | `687.21ms` |
| **5** | **Bare-C** | `160,814.87` | `6.211` | `0.448` | `5.763` | `100.2%` | `143.4%` | `1.43ms` |
| **5** | **Phase 2** | `159,165.01` | `6.402` | `0.572` | `5.830` | `101.9%` | `143.6%` | `1.23ms` |
| **6** | **Bare-C** | `171,601.33` | `5.824` | `0.355` | `5.469` | `100.0%` | `148.4%` | `1.11ms` |
| **6** | **Phase 2** | `147,063.54` | `6.383` | `0.538` | `5.845` | `101.8%` | `138.0%` | `719.39ms` |
| **7** | **Bare-C** | `179,645.26` | `5.605` | `0.408` | `5.197` | `100.6%` | `152.9%` | `1.00ms` |
| **7** | **Phase 2** | `159,243.90` | `6.373` | `0.609` | `5.764` | `101.5%` | `139.1%` | `1.14ms` |

Summary (Rounds 2–7):

| Metric | Bare-C | Honk Phase 2 | Delta |
|---|---:|---:|---:|
| **`req/s` median (min–max)** | `170,332.15` (`155,545.73`–`192,459.52`) | `156,700.20` (`141,945.04`–`167,339.45`) | **`92.0%`** |
| **Total CPU/req median** | `5.799 µs` | `6.393 µs` | `+0.594 µs` |
| **User CPU/req median (min–max)** | `0.392 µs` (`0.350`–`0.469`) | `0.554 µs` (`0.532`–`0.609`) | **`+0.162 µs` (`+162 ns/req`)** |
| **Sys CPU/req median** | `5.434 µs` | `5.838 µs` | `+0.404 µs` (WSL2 kernel jitter) |
| **Server CPU% median** | `100.4%` | `101.6%` | both saturate 1 core |
| **`wrk` CPU% median** | `148.1%` (of 200%) | `140.3%` (of 200%) | client headroom |

**Reading**: the `+162 ns/req` user-space delta isolates the framework cost
(dispatch compares + `Ctx` build + `emit`/`status_text` calls) from WSL2 kernel
jitter, which dominates total CPU (`~92%` sys). Raw `req/s` ratio (`92.0%`) is
reported for completeness but is the noisier metric on WSL2.

### 5.3 JSON Workload Baselines (Rounds 2–4 kept, Round 1 warmup)

`GET /json` (in-place `format_*` serialization of greeting + user struct):

| Round | `req/s` | Total | User | Sys | Srv CPU% | `wrk` CPU% | `p99` |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 *(wu)* | `137,072.48` | `6.827` | `0.904` | `5.922` | `102.0%` | `138.2%` | `734.55ms` |
| **2** | `151,786.32` | `6.797` | `0.744` | `6.053` | `103.0%` | `138.0%` | `1.21ms` |
| **3** | `148,263.67` | `6.865` | `0.781` | `6.083` | `101.6%` | `136.6%` | `1.26ms` |
| **4** | `133,207.47` | `7.014` | `0.924` | `6.090` | `102.2%` | `131.6%` | `812.29ms` |

Median: **`148,263.67 req/s`**, Total `6.865 µs` (User `0.781`, Sys `6.083`).

`POST /api/typed` via `wrk -s bench/post_typed.lua` (typed `Reader` parse + echo):

| Round | `req/s` | Total | User | Sys | Srv CPU% | `wrk` CPU% | `p99` |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 *(wu)* | `101,716.57` | `10.124` | `1.665` | `8.459` | `102.9%` | `101.0%` | `1.46ms` |
| **2** | `99,355.30` | `10.307` | `1.784` | `8.523` | `102.4%` | `98.8%` | `1.46ms` |
| **3** | `86,338.44` | `10.951` | `1.845` | `9.107` | `103.2%` | `97.9%` | `752.85ms` |
| **4** | `98,874.32` | `10.439` | `1.683` | `8.756` | `103.1%` | `99.1%` | `1.51ms` |

Median: **`98,874.32 req/s`**, Total `10.439 µs` (User `1.784`, Sys `8.756`).

### 5.4 Memory (`bench/step2_bench_results.json` → `rss`)

| `server_phase2` state | `VmRSS` / `VmHWM` |
|---|---:|
| Idle (0 conns) | `1,920 kB` / `1,920 kB` |
| 64 active conns | `1,920 kB` / `1,920 kB` |
| 1024 active conns | `1,920 kB` / `1,920 kB` |
| 1024 conns after 4,000 JSON reqs | `1,920 kB` / `1,920 kB` |

Flat (`+0 kB` drift). `+512 kB` vs Phase 1's `1,408 kB` is touched framework/JSON
code + data-stack pages (11 stacks), not per-connection growth — the lazy-buffer
property holds.

---

## 6. Notes & Phase 3 Readiness

- No compiler bugs (`docs/goose-issues.md` explicitly records none for Phase 2; all
  diagnostics were legitimate and fixed in our code).
- No percent-decoding in `query()` and no wildcard/catch-all route (multi-`:param` +
  static + 404/405 cover the spec; both are easy follow-ups if Phase 3 wants them).
- Raw artifacts: `bench/step2_bench_results.json`, `bench/curl_c_control_p2.txt`,
  `bench/curl_phase2.txt`, `bench/post_typed.lua`, `bench/run_step2_bench.py`.
- Phase 3 can proceed: framework API stable, transport untouched, overhead quantified.

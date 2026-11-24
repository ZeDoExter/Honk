# Phase 3 Report — Cross-Framework Benchmark Suite & Public Readiness

> **Single-Core Pinned (`taskset -c 0`) — WSL2 Indicative.** All numbers below were
> collected on WSL2 (Ubuntu 24.04.4 LTS, kernel `6.6.87.2-microsoft-standard-WSL2`,
> Intel Core i5-10300H @ 2.50 GHz, 4C/8T). Servers pinned to CPU `0` (1 worker);
> `wrk -t2 -c64 -d5s --latency` pinned to CPUs `4,6`. Final claims require bare metal.
> Re-run anywhere with one command: `python3 bench/run_phase3.py` (repo root).

## 1. Executive Summary

- **10 contenders, 4 workloads, 0 skipped toolchains.** Honk (bench mode) vs bare-C
  control (W1 only), Rust Axum, Go `net/http`, `Bun.serve`, Elysia, Hono, Fastify,
  Express, FastAPI/uvicorn — all verified for exact behavior (including six `400`
  classes on `POST`) before timing.
- **Honk wins every dynamic workload** (single-core, WSL2 indicative):
  - W1 Plaintext: `83,513 req/s` (2nd to bare C `93,443`; `89.4%` of C).
  - W2 JSON serialize: **`73,477`** vs next Elysia `35,133` (**2.09×**).
  - W3 route+query+middleware: **`73,075`** vs next Bun `24,415` (**2.99×**).
  - W4 parse+validate: **`70,290`** vs next Axum `20,969` (**3.35×**).
- **CPU efficiency**: Honk user-space `0.86–1.57 µs/req` across workloads; nearest
  rivals sit at `7.6–53 µs/req` user.
- **Memory**: Honk `VmRSS` flat at **`2,048 kB`** (idle → 64 → 512 conns + load);
  rivals range from Axum `13.8 MB` to Express `113.9 MB` at 512 conns.
- **Footprint**: Honk binary **`0.17 MiB`** (zero-dependency); cold start **`101 ms`**.
- **Honk changes for Phase 3**: additive, flag-gated bench mode (`HONK_BENCH_MODE`,
  `D-008`) + `src/` package restructure (`D-009`). Full regression green afterward:
  Phase 1 (`900k` turns + 9/9), Phase 2 (10/10 Release + 10/10 ASan+UBSan+LSan, exit 0),
  quickstart (Release + ASan, exit 0).
- **Anything not done**: none. No Elysia/Bun-only comparison — full 10-way shootout
  delivered instead, per the approved change.

---

## 2. Contender Lineup & Exact Versions

| # | Contender | Runtime / compiler | Framework / notes |
|---|---|---|---|
| 1 | Bare-C Control (W1 only) | `gcc 13.3.0` (Ubuntu 24.04) | `epoll` + `picohttpparser`, existing `bench/c_control/server_c` |
| 2 | Honk (Goose) | `goose v2026.4-78-g2239b92e` + `gcc 13.3.0` | `src/server_phase2` bench mode (`... 1 1`) |
| 3 | Rust Axum | `rustc/cargo 1.100.0` | `axum 0.8.9`, `tokio 1.54.1` (`current_thread`), `serde_json 1.0.154`, `--release` |
| 4 | Go `net/http` | `go 1.22.2` | stdlib only, `GOMAXPROCS=1`, `ServeMux` `GET /users/{id}` |
| 5 | `Bun.serve` | `bun 1.4.5` | raw, manual routing, zero deps |
| 6 | Elysia | `bun 1.4.5` | `elysia 1.4.32`, native `t.Object` + strictness guard (see §4) |
| 7 | Hono | `bun 1.4.5` | `hono 4.13.21`, scoped `app.use('/users/:id')` hook |
| 8 | Fastify | `node 20.20.0` | `fastify 5.12.8`, `logger: false`, JSON schema, `coerceTypes: false` |
| 9 | Express | `node 20.20.0` | `express 4.22.3`, route middleware + `express.json()` + 400 error handler |
| 10 | FastAPI | `python 3.12.3` | `fastapi 0.165.0`, `uvicorn 0.54.0` (`--workers 1 --no-access-log`, uvloop+httptools), `pydantic 2.14.4` strict model |

Load generator: `wrk` (`-t2 -c64 -d5s --latency`) + `wrk -s bench/post_users.lua` for W4.

## 3. Workload Definitions (Apples-to-Apples)

| W | Request | Exact expected behavior |
|---|---|---|
| **W1** | `GET /plaintext` | `200`, `text/plain`, `Hello, World!` (13 B). No middleware on any contender. |
| **W2** | `GET /json` | `200`, `application/json`, **dynamically serialized** `{"message":"Hello, World!"}` per request (no pre-serialized literal). |
| **W3** | `GET /users/123?role=admin` | One middleware/hook adds **`X-Frame-Bench: 1`** (scoped to this route); dynamic `{"id":"123","role":"admin"}`. |
| **W4** | `POST /users` `{"name":"alice","age":30,"active":true}` | Validate (`name` non-empty string, `age` integer, `active` boolean) → **`201`** `{"created":true,"name":"alice","age":30}`; six invalid classes → **`400`** (empty name, string age, malformed JSON, missing field, numeric bool, float age). |

**Per-contender implementation notes (no strawmen, no handicaps):**
- Honk: bench-mode routes (§7), `format_*` serialization, `Reader` validation.
- Axum/Go/Bun-raw/Hono/Express: manual validation with identical strictness
  (verified case-by-case in preflight). Go uses `json.Unmarshal` (rejects trailing
  garbage) + `MaxBytesReader` 1 MiB (answers `400` where Honk answers `413` — untested path).
- Elysia: native `t.Object` validation still runs every request; Elysia coerces
  numeric strings (`"30"` → `30`) with no opt-out (`normalize: false` does not cover
  it), so an `onParse` strictness guard rejects mistyped fields first (same single
  `JSON.parse` + native check — no double parse). `VALIDATION`/`PARSE` mapped to `400`.
- Fastify: native JSON schema; `coerceTypes: false` for `"30"`/`1` parity (schema
  failures already yield `400`).
- FastAPI: strict Pydantic model (`StrictStr`/`StrictInt`/`StrictBool`, no coercion);
  `RequestValidationError` (including malformed JSON) mapped to `400`; W3 hook via
  route-scoped `Depends` setting the response header (returns `dict`, not
  `JSONResponse`, so the injected response is actually sent).
- Access logging disabled everywhere (`logger: false`, `--no-access-log`, none by
  default in C/Honk/Axum/Go/Bun/Express).

## 4. Methodology

- **Pinning**: every server `taskset -c 0`, 1 worker (`GOMAXPROCS=1`, `current_thread`,
  single Node process, `--workers 1`, Honk 1 worker). `wrk` on `taskset -c 4,6`.
- **Preflight**: each contender spawned alone; `curl`/socket checks assert every
  workload's status/body/headers plus all six W4 `400`s; W1 `curl -i` saved to
  `bench/preflight_<key>_w1.txt`. Any mismatch aborts before timing.
- **Timing**: per workload, all active contenders spawned (own ports), 3 s `wrk`
  warm-up each, then **5 interleaved round-robin rounds** (`-d5s`), medians reported.
- **Metrics**: `req/s` (median + min–max), `p50`/`p99` (median of round values),
  process `Total/User/Sys CPU µs/req` from `/proc/<pid>/stat` ÷ completed requests,
  `pidstat -u` server/`wrk` CPU% with `<85%` server-CPU client-bottleneck flag.
- **Resources**: `VmRSS`/`VmHWM` at idle / 64 / 512 conns after a 3 s load burst;
  cold-start ms (spawn → first `200`); artifact bytes (`du -sb`).
- Harness: `bench/run_phase3.py` (imports shared helpers from
  `bench/run_step1b_interleaved.py`). Total run: **19.8 min**. Raw data:
  `bench/phase3_results.json`.

## 5. Results — Throughput & CPU (Medians of 5 Rounds)

### W1 — Plaintext (`GET /plaintext`)

| Contender | `req/s` (min–max) | Total | User | Sys | Srv% | `wrk`% | `p50` | `p99` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Bare-C | `93,443` (`81,289`–`96,140`) | `10.686` | `0.748` | `10.057` | `101.2%` | `129.0%` | `568µs` | `2.75ms` |
| **Honk** | **`83,513`** (`80,067`–`88,903`) | **`12.056`** | **`0.863`** | `11.209` | `100.5%` | `124.2%` | `648µs` | `2.85ms` |
| Elysia | `44,689` (`36,676`–`54,957`) | `22.637` | `7.632` | `14.182` | `101.5%` | `72.2%` | `1.24ms` | `3.67ms` |
| Bun | `36,995` (`30,845`–`37,556`) | `27.937` | `10.635` | `17.302` | `101.0%` | `63.0%` | `1.54ms` | `4.22ms` |
| Hono | `36,611` (`26,439`–`45,732`) | `28.114` | `9.335` | `18.779` | `101.5%` | `67.0%` | `1.60ms` | `4.59ms` |
| Axum | `29,052` (`26,688`–`33,984`) | `34.744` | `10.506` | `24.239` | `101.8%` | `64.5%` | `2.05ms` | `5.43ms` |
| Go | `17,668` (`11,452`–`18,982`) | `57.286` | `22.529` | `34.756` | `101.0%` | `52.8%` | `3.61ms` | `9.97ms` |
| Fastify | `10,601` (`7,385`–`11,119`) | `96.429` | `55.612` | `40.719` | `103.0%` | `35.5%` | `5.82ms` | `38.28ms` |
| FastAPI | `4,566` (`3,796`–`4,611`) | `226.466` | `161.198` | `63.380` | `101.8%` | `21.0%` | `13.27ms` | `150.29ms` |
| Express | `3,766` (`2,704`–`3,963`) | `272.134` | `223.330` | `53.937` | `101.8%` | `14.8%` | `14.98ms` | `305.10ms` |

Honk is `89.4%` of bare C on `req/s`; user-space delta vs C is `+115 ns/req`
(`0.863` vs `0.748 µs`).

### W2 — JSON Serialization (`GET /json`)

| Contender | `req/s` (min–max) | Total | User | Sys | Srv% | `wrk`% | `p50` | `p99` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Honk** | **`73,477`** (`60,318`–`79,200`) | **`13.563`** | **`1.208`** | `12.313` | `100.0%` | `121.2%` | `710µs` | `7.86ms` |
| Elysia | `35,133` (`24,812`–`37,628`) | `28.554` | `10.706` | `19.173` | `101.2%` | `68.0%` | `1.49ms` | `14.87ms` |
| Bun | `30,102` (`29,476`–`34,742`) | `29.673` | `11.511` | `18.458` | `101.8%` | `65.8%` | `1.70ms` | `11.65ms` |
| Hono | `24,724` (`21,383`–`27,120`) | `40.519` | `15.659` | `24.860` | `100.8%` | `61.8%` | `2.19ms` | `12.72ms` |
| Axum | `24,444` (`17,803`–`25,700`) | `41.591` | `13.877` | `27.782` | `101.0%` | `66.2%` | `2.35ms` | `11.89ms` |
| Go | `14,966` (`12,277`–`15,362`) | `67.406` | `28.359` | `39.899` | `101.5%` | `51.5%` | `4.25ms` | `15.90ms` |
| Fastify | `8,746` (`7,381`–`9,434`) | `116.719` | `69.201` | `47.481` | `102.0%` | `35.0%` | `6.42ms` | `83.63ms` |
| FastAPI | `2,837` (`2,362`–`3,926`) | `300.909` | `220.747` | `80.163` | `101.0%` | `20.0%` | `16.81ms` | `161.80ms` |
| Express | `2,757` (`1,612`–`3,152`) | `375.195` | `307.452` | `66.623` | `100.0%` | `13.2%` | `18.63ms` | `803.74ms` |

### W3 — Dynamic Routing + Query + Middleware (`GET /users/123?role=admin`)

| Contender | `req/s` (min–max) | Total | User | Sys | Srv% | `wrk`% | `p50` | `p99` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Honk** | **`73,075`** (`54,257`–`80,784`) | **`13.682`** | **`1.283`** | `12.322` | `100.5%` | `116.5%` | `731µs` | `9.28ms` |
| Bun | `24,415` (`22,597`–`24,513`) | `41.690` | `17.857` | `25.135` | `101.8%` | `55.8%` | `2.35ms` | `13.21ms` |
| Elysia | `23,824` (`17,588`–`24,650`) | `42.542` | `17.730` | `25.133` | `101.0%` | `56.4%` | `2.38ms` | `13.11ms` |
| Axum | `20,490` (`15,774`–`22,334`) | `49.483` | `19.515` | `29.825` | `102.0%` | `57.5%` | `2.89ms` | `13.04ms` |
| Hono | `15,121` (`13,877`–`16,514`) | `65.152` | `28.468` | `35.258` | `102.2%` | `47.2%` | `3.75ms` | `16.05ms` |
| Go | `14,795` (`12,474`–`15,828`) | `68.898` | `30.349` | `39.518` | `102.2%` | `48.5%` | `4.34ms` | `16.00ms` |
| Fastify | `8,940` (`7,234`–`9,263`) | `113.710` | `67.831` | `45.299` | `102.0%` | `33.8%` | `6.45ms` | `57.14ms` |
| Express | `2,645` (`2,476`–`3,082`) | `382.315` | `308.880` | `66.118` | `101.8%` | `12.5%` | `19.50ms` | `504.39ms` |
| FastAPI | `1,771` (`1,447`–`1,810`) | `577.487` | `485.307` | `95.872` | `102.5%` | `9.2%` | `31.62ms` | `93.47ms` |

### W4 — JSON Parse + Validate (`POST /users` → `201`/`400`)

| Contender | `req/s` (min–max) | Total | User | Sys | Srv% | `wrk`% | `p50` | `p99` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Honk** | **`70,290`** (`51,736`–`72,560`) | **`14.619`** | **`1.568`** | `13.068` | `100.8%` | `112.0%` | `775µs` | `8.76ms` |
| Axum | `20,969` (`16,486`–`22,336`) | `48.613` | `18.442` | `30.443` | `101.8%` | `58.8%` | `2.82ms` | `13.32ms` |
| Bun | `17,699` (`15,884`–`18,872`) | `57.426` | `24.069` | `32.047` | `101.8%` | `52.2%` | `3.24ms` | `14.91ms` |
| Hono | `14,901` (`13,235`–`16,664`) | `66.138` | `30.849` | `35.446` | `101.8%` | `47.5%` | `3.83ms` | `16.37ms` |
| Go | `12,154` (`10,322`–`12,766`) | `83.913` | `40.343` | `44.440` | `102.0%` | `47.0%` | `5.12ms` | `18.95ms` |
| Elysia | `10,721` (`8,267`–`11,485`) | `95.158` | `53.259` | `43.122` | `101.8%` | `38.0%` | `5.30ms` | `19.59ms` |
| Fastify | `7,199` (`6,345`–`7,495`) | `138.034` | `88.746` | `48.833` | `101.8%` | `29.5%` | `7.77ms` | `124.85ms` |
| FastAPI | `2,580` (`2,520`–`2,753`) | `398.150` | `317.018` | `75.359` | `102.5%` | `15.2%` | `21.47ms` | `286.51ms` |
| Express | `1,814` (`1,585`–`2,054`) | `546.607` | `468.311` | `77.362` | `101.8%` | `9.5%` | `28.60ms` | `999.45ms` |

**Saturation**: every run `SERVER-CORE-BUSY` (server ≈`100–104%`, `0` client-saturated
runs); `wrk` keeps headroom on all workloads (≤`129%` of 200%).

### Round-by-Round `req/s` (R1–R5, interleaved)

W1: C `81289 85936 96140 93443 94959`; Honk `82747 80067 85697 88903 83513`;
Axum `33984 29118 27891 26688 29052`; Go `17668 11452 18926 17607 18982`;
Bun `37556 30845 37251 36995 36268`; Elysia `44689 54957 44443 50830 36676`;
Hono `42075 36611 26439 45732 34838`; Fastify `7385 10483 10601 11119 10815`;
Express `3766 3375 3959 2704 3963`; FastAPI `4587 3796 4566 4611 4502`.

W2: Honk `60318 79200 73477 78964 69303`; Axum `17803 24444 23613 25700 24877`;
Go `13861 15234 12277 15362 14966`; Bun `30102 29476 34510 34742 29563`;
Elysia `24812 32958 36379 35133 37628`; Hono `24724 21383 27120 23144 25334`;
Fastify `8677 8746 9251 7381 9434`; Express `2912 2682 3152 2757 1612`;
FastAPI `2698 3926 2837 3597 2362`.

W3: Honk `54257 76026 62328 80784 73075`; Axum `20490 15774 18521 20616 22334`;
Go `13503 15828 15124 14795 12474`; Bun `22597 23624 24446 24513 24415`;
Elysia `23824 17588 22994 24273 24650`; Hono `15624 14613 16514 13877 15121`;
Fastify `7234 8940 9263 9070 8502`; Express `2639 2476 3082 2645 2952`;
FastAPI `1614 1771 1447 1794 1810`.

W4: Honk `70290 72560 51736 70828 63523`; Axum `22336 21610 20969 19600 16486`;
Go `12714 12766 11781 10322 12154`; Bun `18561 15884 17699 18872 16984`;
Elysia `11485 11095 8652 8267 10721`; Hono `13235 16664 14901 15612 14751`;
Fastify `7199 7478 6345 7495 7113`; Express `2054 1585 1814 1887 1667`;
FastAPI `2520 2580 2752 2588 2539`.

Full per-round CPU/latency rows: `bench/phase3_results.json`.

## 6. Resources, Startup & Footprint

### `VmRSS` / `VmHWM` (`kB`)

| Contender | Idle | 64 conns | 512 conns + load (`VmHWM`) |
|---|---:|---:|---:|
| Bare-C | `1,408` | `1,408` | `1,536` (`1,536`) |
| **Honk** | **`2,048`** | **`2,048`** | **`2,048`** (`2,048`) |
| Axum | `2,688` | `3,968` | `13,824` (`13,824`) |
| Go | `6,016` | `7,040` | `23,168` (`23,168`) |
| Bun | `26,624` | `28,256` | `40,172` (`47,452`) |
| Elysia | `44,812` | `43,496` | `53,244` (`57,560`) |
| Hono | `32,384` | `33,896` | `43,596` (`52,828`) |
| Fastify | `66,804` | `67,700` | `79,660` (`79,660`) |
| Express | `57,372` | `58,524` | `113,892` (`113,892`) |
| FastAPI | `48,828` | `49,340` | `54,972` (`54,972`) |

Honk is the only contender besides bare C with zero connection-driven growth
(lazy C tail buffers; per-request data stacks reclaimed per turn).

### Cold Start (spawn → first `200`, ms)

| C | Honk | Axum | Go | Bun | Elysia | Hono | Fastify | Express | FastAPI |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `106` | `101` | `103` | `106` | `215` | `915` | `205` | `4,936` | `2,119` | `3,822` |

Node/Python/bun-framework startups pay 9P filesystem import cost on this WSL2
box (hundreds of `node_modules`/venv files over `/mnt/c`); native binaries are
unaffected. Disclosed, not normalized.

### Artifact Footprint (`du -sb`)

| C | Honk | Axum | Go | Bun* | Elysia† | Hono† | Fastify† | Express† | FastAPI‡ |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `0.03 MiB` | **`0.17 MiB`** | `1.88 MiB` | `7.07 MiB` | `102.42 MiB` | `3.55 MiB` | `1.26 MiB` | `8.16 MiB` | `2.26 MiB` | `52.10 MiB` |

\* shared `bun` runtime binary; † `node_modules` (+ runtime); ‡ venv.

## 7. Honk Bench Mode & Package Layout (`D-008`, `D-009`)

- **Bench mode** (`HONK_BENCH_MODE`, worker-TLS global, `argv[5]`): workload-exact
  routes on the standard paths — `/json` → exactly `{"message":"Hello, World!"}`,
  `GET /users/:id` → `{"id","role"}` with only `X-Frame-Bench` staged (by `mw_bench`,
  replacing the decoration chain), `POST /users` → strict validate → `201`/`400`.
  Default mode is behavior-identical to Phase 2 (all Phase 2 tests run with flag `0`).
- **Preflight parity**: Honk passed the same 200 + six-400 checks as every contender,
  plus the 115-byte W1 shape check.
- **`src/` packages**: framework files moved to `src/honk_net/`, `src/honk_ctx/`,
  `src/honk_json/`, `src/honk_router/` (Goose packages need a directory of their own;
  a single root cannot import several modules from one directory). Roots declare
  packages (`import honk_net from "./honk_net";`), libraries reference them bare
  (`import honk_net;`). External apps (e.g. `examples/quickstart/`) import the same way.

## 8. Regression & Sanitizers (After All Phase 3 Honk Changes)

| Gate | Result |
|---|---|
| `test_stack_discipline` (`900k` turns) | **PASS** |
| `test_phase1_correctness.py` (9 tests, Release) | **PASS** |
| `test_phase2_framework.py` (10 tests, Release) | **PASS** |
| `test_phase2_framework.py` (10 tests, ASan+UBSan+LSan, rebuilt) | **PASS**, exit `0`, **0 findings** |
| `examples/quickstart` (Release + ASan, curl-verified) | **PASS**, exit `0`, **0 findings** |

## 9. Disclosures & Limitations

- WSL2 indicative numbers; hypervisor jitter visible in min–max spreads (medians +
  interleaving absorb it; ratios are the robust readout).
- Absolute `req/s` is lower than the Phase 2 solo runs (e.g. Honk W1 `83.5k` here vs
  `156.7k` there): all contender servers idle simultaneously on CPU `0` during each
  workload, plus shorter `-d5s` runs. Honk-vs-C ratio is preserved (`89–92%`).
- `p99` spikes (hundreds of ms) on some rounds are WSL2 scheduling artifacts, present
  across all contenders including bare C.
- Go contender is stdlib `net/http` (not Fiber); bare-C covers W1 only (as specified).
- Contender sources: `bench/competitors/<name>/` (all runnable, pinned lockfiles
  committed). No toolchain was skipped.

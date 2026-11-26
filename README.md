# Honk — a zero-copy HTTP framework in Goose

Honk is an HTTP/1.1 backend framework written in [Goose](https://github.com/aardappel/goose)
(ahead-of-time compiled to C) for Linux `epoll` servers: a **4-line single-file Hello World**,
**~2 MB flat RSS**, a **~150 KiB zero-dependency binary**, and zero per-request
heap allocations — at `95%` of hand-written C speed.

```sh
git clone https://github.com/ZeDoExter/Honk.git && cd Honk
./honk doctor                              # checks gcc + pinned Goose + wrk
./honk new my-api && ./honk dev my-api     # scaffold single main.goose + auto-reload
curl http://127.0.0.1:18080/               # Hello from my-api!
```

A complete Hello World is **4 lines of Goose** (no `.build` file needed):

```goose
import honk from "ZeDoExter/Honk@v1.0.1";
fn main() {
    honk::listen(18080) { app => app.get("/", "Hello, World!"); };
}
```

Static routes, `:params`, `*` wildcards, and streaming JSON in **9 lines** —
with automatic `404` / `405` handling and zero closure allocations:

```goose
import honk from "ZeDoExter/Honk@v1.0.1";
fn main() {
    honk::listen(18080) { app =>
        app.get("/health", "ok");
        app.get("/users/:name") { app.ok(app.param("name")); };
        app.get("/files/*") { app.ok(app.tail); };
        app.get("/json") { app.json() { j => j.set("message", "Hello, World!"); }; };
    };
}
```

New to Goose? [`docs/QUICKSTART.md`](docs/QUICKSTART.md) gets you productive in
5 minutes with a JS/Go/Python cheat sheet. Never heard of `epoll`? Good — you
will never touch it: routing, JSON, static `sendfile`, SQLite, and buffers are
zero-copy machinery under a short, readable API.

How it gets there:

- **Zero-copy I/O**: the kernel `recv()`s straight into the top of Goose's per-request
  data-stack buffer (`gs_rref`); only genuinely split request tails spill to lazily
  allocated C side buffers (`partial_rx` / `pending_tx`, freed on drain/close).
- **Zero-copy views**: method, path, query, headers, params, and body are slices into
  the request buffer — parsed in place with `picohttpparser`, never copied.
- **Scoped builders**: per-request builders live in an explicit inner scope and reset
  on every pipelined request (verified in generated C).
- **Dispatch-as-code**: `honk::listen`, `app.get/post/...`, and `app.json` are `inline fn`s
  that monomorphize straight into the worker loop — static route patterns fold at
  compile time, with no function-pointer tables and no per-request closures.

## Documentation index

| Doc | For |
|---|---|
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | 5-minute tutorial + Goose cheat sheet |
| [`docs/GUIDE.md`](docs/GUIDE.md) | Recipes: routing, JSON, auth, CORS, cookies, static, SQLite, deploy |
| [`docs/API.md`](docs/API.md) | Every public function, one table per module |
| [`examples/quickstart/`](examples/quickstart/) | Commented single-file API (`:params`, bearer auth, validated JSON POST) |
| [`examples/fullstack_todo/`](examples/fullstack_todo/) | ~45-line single-file Todo app (`sendfile` UI + SQLite API) |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Architecture decision record (D-001…) |
| [`docs/history/`](docs/history/) | Development log: transport → framework → shootout → DX → v0.1.0 |

## Build, test, deploy

```sh
./honk test                                # everything: 900k turns + suites + ASan
./honk new my-api --git                    # standalone repo pinned to ZeDoExter/Honk@v1.0.1
./honk build my-api --release              # -> my-api/dist/main, zero dependencies
./my-api/dist/main 8080                    # single worker (SIGINT/SIGTERM drains cleanly)
HONK_WORKERS=auto ./my-api/dist/main 8080  # scale across all available CPU cores
```

```sh
# Docker, no local toolchain:
docker build -t honk:quickstart . && docker run --rm -p 18080:18080 honk:quickstart
```

### Manual commands (what `./honk` wraps)

```sh
# Any app imports honk.goose + honk.build directly — no per-app .build file needed:
./goose_repo/build-linux/goose build examples/quickstart/app.goose -o /tmp/app
/tmp/app 18080

# Regression (WSL2/Linux): 900k stack-discipline turns + correctness suites
./test/test_stack_discipline
python3 test/test_transport.py ./src/server_minimal
python3 test/test_framework.py ./src/server 18210 Release

# Hardened build (ASan + UBSan + LSan; must exit 0 with zero findings):
./honk build examples/quickstart --asan
```

**Deploy**: ship the Release binary as-is — it links only libc/pthreads (`0.15 MiB`,
no runtime, no `node_modules`, no venv). Terminate TLS in a reverse proxy (nginx,
Caddy); Honk speaks plain HTTP/1.1 with keep-alive + pipelining.

## How fast is it?

10-framework shootout, single core pinned (`taskset -c 0`, 1 worker each),
`wrk -t2 -c64 -d5s` on sibling cores, 5 interleaved rounds, medians.
**WSL2 indicative** — ratios are the robust readout; re-run on bare metal with
`python3 bench/run_bench_compete.py`. Full methodology + versions:
[`docs/history/phase3-report.md`](docs/history/phase3-report.md); round data:
`bench/bench_compete_results.json` (re-measured on current `master`, control
rebuilt `gcc -O2` + `picohttpparser.c`).

**Throughput, `req/s` (median of 5)**

| Framework | W1 Plaintext | W2 JSON | W3 Route+MW | W4 Validate |
|---|---:|---:|---:|---:|
| Bare C (epoll) | `124,004` | — | — | — |
| **Honk** | **`117,950`** | **`120,951`** | **`108,357`** | **`109,596`** |
| Rust Axum | `54,253` | `49,249` | `35,885` | `36,179` |
| Go net/http | `27,044` | `24,150` | `22,514` | `19,664` |
| Bun.serve | `63,682` | `63,059` | `35,086` | `30,240` |
| Elysia (Bun) | `74,667` | `66,435` | `32,895` | `17,303` |
| Hono (Bun) | `63,583` | `49,275` | `23,801` | `24,659` |
| Fastify (Node) | `15,299` | `14,285` | `14,092` | `12,414` |
| Express (Node) | `5,407` | `5,679` | `5,056` | `3,967` |
| FastAPI (uvicorn) | `6,932` | `6,329` | `3,146` | `4,555` |

Honk is `95%` of hand-written C on plaintext and **1.8–3.0× the nearest rival**
on every dynamic workload (`3.0×` on route+middleware and validation).
User-space cost stays at `0.67–0.98 µs/req` (rivals: `4.1–248 µs/req`).

**Memory (`VmRSS`, idle → 512 conns + load) · Cold start · Artifact**

| Framework | Idle | 512 conns | Cold start | Artifact |
|---|---:|---:|---:|---:|
| Bare C | `1,408 kB` | `1,536 kB` | `103 ms` | `0.03 MiB` |
| **Honk** | **`2,176 kB`** | **`2,304 kB`** | **`101 ms`** | **`0.20 MiB`** |
| Axum | `2,688 kB` | `13,824 kB` | `103 ms` | `1.88 MiB` |
| Go | `6,016 kB` | `22,496 kB` | `112 ms` | `7.06 MiB` |
| Bun / Elysia / Hono | `26–44 MB` | `36–51 MB` | `213 ms–1.9 s` | `102 MB` runtime + `1–4 MB` modules |
| Fastify / Express | `56–65 MB` | `78–102 MB` | `4.6–7.5 s`* | `2–8 MB` modules |
| FastAPI | `48 MB` | `54 MB` | `4.6 s`* | `52 MB` venv |

\* Node/Python cold starts pay WSL2 9P filesystem import cost on this box (disclosed,
not normalized); steady-state numbers are unaffected.

Every contender implements identical behavior — verified by preflight (status codes,
bodies, `X-Frame-Bench` hook header, six `400` classes) before timing. No access logs,
no pre-serialized literals, no strawman configs.

## Capabilities & roadmap

**Today**: `./honk` CLI (`setup`/`doctor`/`new [--git]`/`dev`/`build`/`test`),
zero-sidecar `honk` package (`import honk from "ZeDoExter/Honk@v1.0.1";`),
one-call `honk::listen` + unified pattern routing (`get`/`post`/`put`/`patch`/`delete`/`options`/`all`,
nestable `app.group("/api")`, named `app.param("id")` + `param_dec` + suffixes like `/todos/:id/toggle`,
`/*` `app.tail`, typed `*_int` routes, and automatic `404`/`405` tracking),
one-line lifecycle & guards (`app.cors()`, `app.bearer()`, `app.rate_limit()`,
`app.json_errors()`, `app.server_timing()`, `app.after()`), opt-in zero-dependency
`honk_auth` (`HS256` JWT issue/verify/guard + HMAC-signed cookies + `delete_cookie`),
nested `app.json` / `app.json_list` streaming (`j.set`, `j.obj`, `j.arr`) +
field-named `require_*` validators, URL-encoded forms (`app.form`, `require_form`) +
zero-copy RFC 7578 `multipart/form-data` file uploads (`app.multipart_file`, `each_part`),
outbound HTTP/1.1 chunked streaming (`app.stream`) + Server-Sent Events (`app.sse`),
inbound `Transfer-Encoding: chunked` request decoding (with `CL+TE` smuggling defense),
opt-in non-blocking RFC 6455 WebSockets (`honk_ws`: `app.ws` per-message callback, `send_json`, auto `Ping`/`Pong`),
opt-in OpenAPI `3.1.0` + interactive Scalar Docs UI (`honk_openapi`: `app.openapi`, `app.docs`),
`client_ip` / `real_ip`, kernel-`sendfile` static serving (`static_dir` +
`ETag`/`304 Not Modified`) + single-binary compile-time `app.embed` (`embed_file`),
opt-in `sqlite/` package (`db_connect`, `BOOLEAN`-aware `sql_json` streaming,
`insert_text`/`run_int` + low-level `Stmt`), opt-in zero-socket in-memory unit
test harness (`honk::tester()`), strict `400`/`404`/`405`/`429` + `413`/`431`/`501`
caps, idle + slowloris timeouts, `SIGINT`/`SIGTERM` graceful outbound drain,
zero-code `$HONK_WORKERS` / `honk::listen_workers` `SO_REUSEPORT` multi-core
scaling, Linux `epoll`, Docker + GitHub Actions CI.

**Not yet**: TLS (terminate at a reverse proxy), HTTP/2+. See
[`docs/DECISIONS.md`](docs/DECISIONS.md) for the architecture record and
[`docs/history/`](docs/history/) for the development log.

# Honk — a zero-copy HTTP framework in Goose

Honk is an HTTP/1.1 backend framework written in [Goose](https://github.com/aardappel/goose)
(ahead-of-time compiled to C) for Linux `epoll` servers: a 15-line Hello World,
**~2 MB flat RSS**, a **~150 KiB zero-dependency binary**, and zero per-request
heap allocations — at `89%` of hand-written C speed.

```sh
git clone https://github.com/ZeDoExter/Honk.git && cd Honk
./honk doctor               # checks gcc + pinned Goose + wrk
./honk new my-api && ./honk dev my-api     # scaffold + auto-reload dev server
curl http://127.0.0.1:18080/               # Hello from my-api!
```

A complete Hello World + JSON app is ~15 lines of Goose:

```goose
import honk_serve from "/path/to/Honk/src/honk_serve";  // (+ honk_net, honk_ctx)

thread_fn worker(port: i32) {
    honk::listen_or_abort(port);
    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.method == "GET" && ctx.path == "/" {
                ctx.text(200, "Hello, World!");
            } else if ctx.method == "GET" && ctx.path == "/json" {
                ctx.res.append("{\"message\":\"Hello, World!\"}");
                ctx.json_raw(200, ctx.res[..]);
            }   // anything else answers 404 automatically
        };
    };
}

fn main() {
    let tid = thread_spawn(worker, 18080);
    thread_wait(tid);
}
```

New to Goose? [`docs/QUICKSTART.md`](docs/QUICKSTART.md) gets you productive in
5 minutes with a JS/Go/Python cheat sheet. Never heard of `epoll`? Good — you
will never touch it: routing, JSON, middleware, and buffers are
zero-copy machinery under a boring, obvious API.

How it gets there:

- **Zero-copy I/O**: the kernel `recv()`s straight into the top of Goose's per-request
  data-stack buffer (`gs_rref`); only genuinely split request tails spill to lazily
  allocated C side buffers (`partial_rx` / `pending_tx`, freed on drain/close).
- **Zero-copy views**: method, path, query, headers, params, and body are slices into
  the request buffer — parsed in place with `picohttpparser`, never copied.
- **Scoped builders**: per-request builders live in an explicit inner scope and reset
  on every pipelined request (verified in generated C).
- **Dispatch-as-code**: routes and middleware monomorphize straight into the worker
  loop — no function-pointer tables, no per-request closures.

## Documentation index

| Doc | For |
|---|---|
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | 5-minute tutorial + Goose cheat sheet |
| [`docs/GUIDE.md`](docs/GUIDE.md) | Recipes: routing, JSON, auth, CORS, cookies, static, SQLite, deploy |
| [`docs/API.md`](docs/API.md) | Every public function, one table per module |
| [`examples/quickstart/`](examples/quickstart/) | Full commented example app |
| [`examples/fullstack_todo/`](examples/fullstack_todo/) | Single-binary Todo app (sendfile UI + SQLite API) |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Architecture decision record (D-001…) |
| [`docs/history/`](docs/history/) | Development log: transport → framework → shootout → DX → v0.1.0 |

## Build, test, deploy

```sh
./honk test                        # everything: 900k turns + suites + ASan
./honk build my-api --release      # -> my-api/dist/main, zero dependencies
./my-api/dist/main 8080
```

```sh
# Docker, no local toolchain:
docker build -t honk:quickstart . && docker run --rm -p 18080:18080 honk:quickstart
```

### Manual commands (what `./honk` wraps)

```sh
# Framework demo server (all routes + cross-framework bench mode via argv[5]=1):
./goose_repo/build-linux/goose build src/server.goose -o /tmp/honk
/tmp/honk 18080 30000 10000 1              # port, idle_ms, header_ms, workers

# Regression (WSL2/Linux): 900k stack-discipline turns + correctness suites
./test/test_stack_discipline
python3 test/test_transport.py ./src/server_minimal
python3 test/test_framework.py ./src/server 18210 Release

# Hardened build (ASan + UBSan + LSan; must exit 0 with zero findings):
./goose_repo/build-linux/goose -o /tmp/honk.c --standalone src/server.goose
gcc -O2 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Isrc/shim -Igoose_repo/src/runtime /tmp/honk.c \
  src/shim/honk_shim.c src/shim/picohttpparser.c -o /tmp/honk_asan -lm -pthread -ldl
```

**Deploy**: ship the Release binary as-is — it links only libc/pthreads (`0.17 MiB`,
no runtime, no `node_modules`, no venv). Terminate TLS in a reverse proxy (nginx,
Caddy); Honk speaks plain HTTP/1.1 with keep-alive + pipelining.

## How fast is it?

10-framework shootout, single core pinned (`taskset -c 0`, 1 worker each),
`wrk -t2 -c64 -d5s` on sibling cores, 5 interleaved rounds, medians.
**WSL2 indicative** — ratios are the robust readout; re-run on bare metal with
`python3 bench/run_bench_compete.py`. Full methodology + versions + round data:
[`docs/history/phase3-report.md`](docs/history/phase3-report.md).

**Throughput, `req/s` (median of 5)**

| Framework | W1 Plaintext | W2 JSON | W3 Route+MW | W4 Validate |
|---|---:|---:|---:|---:|
| Bare C (epoll) | `93,443` | — | — | — |
| **Honk** | **`83,513`** | **`73,477`** | **`73,075`** | **`70,290`** |
| Rust Axum | `29,052` | `24,444` | `20,490` | `20,969` |
| Go net/http | `17,668` | `14,966` | `14,795` | `12,154` |
| Bun.serve | `36,995` | `30,102` | `24,415` | `17,699` |
| Elysia (Bun) | `44,689` | `35,133` | `23,824` | `10,721` |
| Hono (Bun) | `36,611` | `24,724` | `15,121` | `14,901` |
| Fastify (Node) | `10,601` | `8,746` | `8,940` | `7,199` |
| Express (Node) | `3,766` | `2,757` | `2,645` | `1,814` |
| FastAPI (uvicorn) | `4,566` | `2,837` | `1,771` | `2,580` |

Honk is `89%` of hand-written C on plaintext and **2.1–3.4× the nearest rival** on
every dynamic workload. User-space cost stays at `0.86–1.57 µs/req` (rivals:
`7.6–468 µs/req`).

**Memory (`VmRSS`, idle → 512 conns + load) · Cold start · Artifact**

| Framework | Idle | 512 conns | Cold start | Artifact |
|---|---:|---:|---:|---:|
| Bare C | `1,408 kB` | `1,536 kB` | `106 ms` | `0.03 MiB` |
| **Honk** | **`2,048 kB`** | **`2,048 kB`** | **`101 ms`** | **`0.17 MiB`** |
| Axum | `2,688 kB` | `13,824 kB` | `103 ms` | `1.88 MiB` |
| Go | `6,016 kB` | `23,168 kB` | `106 ms` | `7.07 MiB` |
| Bun / Elysia / Hono | `27–45 MB` | `40–53 MB` | `205–915 ms` | `102 MB` runtime + `1–4 MB` modules |
| Fastify / Express | `57–67 MB` | `80–114 MB` | `2.1–4.9 s`* | `2–8 MB` modules |
| FastAPI | `49 MB` | `55 MB` | `3.8 s`* | `52 MB` venv |

\* Node/Python cold starts pay WSL2 9P filesystem import cost on this box (disclosed,
not normalized); steady-state numbers are unaffected.

Every contender implements identical behavior — verified by preflight (status codes,
bodies, `X-Frame-Bench` hook header, six `400` classes) before timing. No access logs,
no pre-serialized literals, no strawman configs.

## Capabilities & roadmap

**Today**: `./honk` CLI (`setup`/`doctor`/`new`/`dev`/`build`/`test`), one-call
`honk::serve` API, zero-copy routing (`:params`, typed `param_int`, query +
percent-decoding, headers), composable middleware, CORS, cookies, bearer auth,
`HEAD`, stdlib JSON (`Reader` typed binding, DOM `parse`, `format_*` emit),
kernel-`sendfile` static file serving, opt-in SQLite (WAL + prepared
statements, zero-copy rows), strict `400`/`404`/`405` + `413`/`431`/`501` caps,
idle + slowloris timeouts, `SO_REUSEPORT` multi-worker with CPU pinning, Linux
`epoll`, Docker + GitHub Actions CI.

**Not yet**: TLS (terminate at a reverse proxy), HTTP/2+, chunked request bodies
(`501`), WebSockets. See [`docs/DECISIONS.md`](docs/DECISIONS.md) for the
architecture record and [`docs/history/`](docs/history/) for the development log.

# Honk — a zero-copy HTTP framework in Goose

Honk is an HTTP/1.1 backend framework written in [Goose](https://github.com/aardappel/goose)
(ahead-of-time compiled to C) for Linux `epoll` servers that do more work per core with
less memory: **~2 MB RSS**, a **0.17 MiB zero-dependency binary**, and zero per-request
heap allocations.

How it gets there:

- **Zero-copy I/O**: the kernel `recv()`s straight into the top of Goose's per-request
  data-stack buffer (`gs_rref`); only genuinely split request tails spill to lazily
  allocated C side buffers (`partial_rx` / `pending_tx`, freed on drain/close).
- **Zero-copy views**: method, path, query, headers, params, and body are slices into
  the request buffer — parsed in place with `picohttpparser`, never copied.
- **Scoped builders**: per-request `body`/`scratch`/JSON buffers live in an explicit
  inner scope and reset to base on every pipelined request (verified in generated C).
- **Dispatch-as-code**: routes and middleware are inline functions that fold directly
  into the worker loop — no function-pointer tables, no per-request closures.

## Quickstart

```sh
git clone https://github.com/ZeDoExter/Honk.git && cd Honk
# Goose ships pinned in ./goose_repo (v2026.4-78-g2239b92e); build it once:
#   (see goose_repo README — needs gcc/clang + cmake)
./goose_repo/build-linux/goose build examples/quickstart/app.goose -o /tmp/honk-qs
/tmp/honk-qs 18080
```

```sh
curl "http://127.0.0.1:18080/hello/ada?title=Dr"     # Hello, Dr ada!
curl -X POST http://127.0.0.1:18080/signup \
  -H "Content-Type: application/json" \
  -d '{"username":"ada","email":"ada@honk.dev"}'     # {"created":true,...}
```

Full walkthrough (routes, params, query, middleware, guards, typed JSON POST,
sanitizer build): [`examples/quickstart/`](examples/quickstart/).

A 40-line taste (`app.goose` dispatch + handler):

```goose
inline fn h_hello(c: Ctx&, body_buf: u8[>..]&) {
    let title, ok = c.query("title");          // zero-copy view into rx_buf
    body_buf.append("Hello, ");
    if ok { body_buf.append(title); body_buf.push(' '); }
    body_buf.append(c.param(0));               // :name, zero-copy
    body_buf.push('!');
    c.text(200, body_buf);                     // staged; emit() frames once
}
```

## Build, test, deploy

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
[`docs/phase3-report.md`](docs/phase3-report.md).

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

**Today**: HTTP/1.1 keep-alive + pipelining, zero-copy routing (`:params`, query,
headers), composable middleware, `HEAD`, stdlib JSON (`Reader` typed binding, DOM
`parse`, `format_*` emit), strict `400`/`404`/`405` + `413`/`431`/`501` caps, idle +
slowloris timeouts, `SO_REUSEPORT` multi-worker with CPU pinning, Linux `epoll`.

**Not yet**: TLS (terminate at a reverse proxy), HTTP/2+, chunked request bodies
(`501`), directory serving / static files, WebSockets. See
[`docs/DECISIONS.md`](docs/DECISIONS.md) for the architecture record and
[`docs/phase3-report.md`](docs/phase3-report.md) for benchmark details.

# Honk Quickstart (5 minutes)

You know TypeScript, Go, or Python, but have never seen Goose? Perfect — you only
need **five** Goose ideas (cheat sheet below) to ship a Honk API.

## 0. Prerequisites

- Linux or WSL2, `gcc`, `python3`, `git`
- This repo (Goose ships pinned inside `./goose_repo`)

```sh
./honk doctor     # checks everything, tells you how to fix gaps
```

## 1. Scaffold and run

```sh
./honk new my-api && ./honk dev my-api
```

Open another terminal:

```sh
curl http://127.0.0.1:18080/
curl http://127.0.0.1:18080/users/42
curl -X POST http://127.0.0.1:18080/users \
  -H "Content-Type: application/json" -d '{"name":"ada","age":36}'
```

Edit `my-api/main.goose`, save — the dev server rebuilds and restarts by itself
(like `bun --watch`). `Ctrl-C` stops it.

## 2. Ship it

```sh
./honk build my-api --release     # -> my-api/dist/main  (~150 KiB, zero deps)
./my-api/dist/main 8080           # runs anywhere Linux: VPS, VM, container
```

Or hardened: `./honk build my-api --asan` (AddressSanitizer + UBSan + leak checks).
Or containerized: see `Dockerfile` (2 commands, no local Goose install needed).

## 3. Goose cheat sheet for JS/Go/Python devs

You will only meet these five constructs in Honk apps:

| You know (JS / Go / Python) | Goose in Honk | Example |
|---|---|---|
| `string` slice / `&str` / `str` | `const u8[:]` — a **view** (pointer + length), never copied | `ctx.path`, `ctx.body` |
| `struct` / `struct` / `dataclass` | `struct` with fields; `Ctx { method: m, .. }` fills the rest with defaults | `honk::Config { port: 8080, .. }` |
| `val, err := …` / destructuring | `let val, ok = …` — multiple return values, no exceptions | `let id, ok = ctx.param_int(0);` |
| `Buffer` / `bytes.Buffer` / `bytearray` | `u8[>..]&` — a growable builder (`out.append(x)`, `out.push(c)`); auto-freed at scope exit | `ctx.res.append("hi")` |
| arrow fn / closure / `def` | trailing block `{ arg => … }` — inlined at compile time (**never `return`/`break` inside; use if/else**) | `honk::request(fd, d) { ctx => … };` |

Everything else is plain `if`/`else`, `for x in n`, `while`, `==`, `+` — exactly
like you expect. Types you will see: `i64` (int), `u8` (byte), `bool`,
`const u8[:]` (read-only view). A leading `&` (`Ctx&`) means "by reference".

## 4. The 15-line app

```goose
import std;
import os;
import honk_net from "/path/to/Honk/src/honk_net";
import honk_ctx from "/path/to/Honk/src/honk_ctx";
import honk_serve from "/path/to/Honk/src/honk_serve";

thread_fn worker(port: i32) {
    honk::listen_or_abort(port);
    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.method == "GET" && ctx.path == "/" {
                ctx.text(200, "Hello, World!");
            } else if ctx.method == "GET" && ctx.path == "/json" {
                ctx.res.append("{\"message\":\"Hello, World!\"}");
                ctx.json_raw(200, ctx.res[..]);
            }
        };
    };
}

fn main() {
    let tid = thread_spawn(worker, 18080);
    thread_wait(tid);
}
```

Unmatched paths answer `404` automatically. Next: [`GUIDE.md`](GUIDE.md) for
routing, JSON validation, auth, CORS, cookies, and deployment recipes.

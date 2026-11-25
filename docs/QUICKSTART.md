# Honk Quickstart (5 minutes)

You know TypeScript, Go, or Python, but have never seen Goose? Perfect — you only
need **five** Goose ideas (cheat sheet below) to ship a Honk API.

## 0. Prerequisites

- Linux or WSL2, `gcc`, `python3`, `git`
- This repo (`./honk setup` fetches and builds the pinned Goose compiler if needed)

```sh
./honk doctor     # checks everything, tells you how to fix gaps
```

## 1. Scaffold and run

```sh
./honk new my-api && ./honk dev my-api        # portable relative import (works offline)
# or: ./honk new my-api --git                 # pinned to "ZeDoExter/Honk@v0.10.0"
```

Notice only **one file** is created (`my-api/main.goose`) — Honk packages its own C
shim via `honk.build`, so your app needs no `.build` file. Open another terminal:

```sh
curl http://127.0.0.1:18080/
curl http://127.0.0.1:18080/users/42
curl -X POST http://127.0.0.1:18080/users \
  -H "Content-Type: application/json" -d '{"name":"ada","age":36}'
```

Edit `my-api/main.goose`, save — the dev server rebuilds and restarts automatically.
`Ctrl-C` stops and drains it cleanly.

## 2. Ship it

```sh
./honk build my-api --release               # -> my-api/dist/main (~150 KiB, zero deps)
./my-api/dist/main 8080                     # single worker; Ctrl-C / SIGTERM drains cleanly
HONK_WORKERS=auto ./my-api/dist/main 8080   # fork SO_REUSEPORT workers across all cores
```

Or hardened: `./honk build my-api --asan` (AddressSanitizer + UBSan + leak checks).
Or containerized: see `Dockerfile` (2 commands, no local Goose install needed).

## 3. Goose cheat sheet for JS/Go/Python devs

You will only meet these five constructs in Honk apps:

| You know (JS / Go / Python) | Goose in Honk | Example |
|---|---|---|
| `string` slice / `&str` / `str` | `const u8[:]` — a **view** (pointer + length), never copied | `app.path`, `app.param("id")` |
| `struct` / `struct` / `dataclass` | `struct` with fields; `Config { port: 8080, .. }` fills defaults | `honk::Config { port: 8080, .. }` |
| `val, err := …` / destructuring | `let val, ok = …` — multiple return values, no exceptions | `let age, ok = app.body_int("age");` |
| `Buffer` / `bytes.Buffer` / `bytearray` | `u8[>..]&` — a growable builder (`out.append(x)`, `out.push(c)`); auto-freed at scope exit | `app.res.append("hi")` |
| arrow fn / closure / `def` | trailing block `{ arg => … }` — inlined at compile time (**never `return`/`break` inside; use if/else**) | `honk::listen(18080) { app => … };` |

Everything else is plain `if`/`else`, `for x in n`, `while`, `==`, `+` — exactly
like you expect. Types you will see: `i64` (int), `f64` (float), `u8` (byte),
`bool`, `const u8[:]` (read-only view). A trailing `&` (`honk::Ctx&`) means "by reference".

## 4. From 4 lines to a JSON API

A minimal server is 4 lines in a single `.goose` file:

```goose
import honk from "ZeDoExter/Honk@v0.10.0";
fn main() {
    honk::listen(18080) { app => app.get("/", "Hello, World!"); };
}
```

Add `:params`, `*` wildcards, overloaded `j.set` JSON streaming, and validated
`POST` bodies with zero boilerplate:

```goose
import honk from "ZeDoExter/Honk@v0.10.0";

fn main() {
    honk::listen(honk::arg_port(18080)) { app =>
        app.get("/", "Hello, World!");
        app.get("/users/:id") {
            app.json() { j => j.set("id", app.param("id")); };
        };
        app.post("/users") {
            app.require_str("name") { name =>
                let age, ok = app.body_int("age");
                if !ok {
                    app.json_error(400, "age (int) required");
                } else {
                    app.created_json() { j =>
                        j.set("created", true);
                        j.set("name", name);
                        j.set("age", age);
                    };
                }
            };
        };
    };
}
```

Unmatched paths answer `404` automatically; a matched path with the wrong HTTP
method answers `405 Method Not Allowed`. Next: [`GUIDE.md`](GUIDE.md) for
routing, JSON validation, auth, CORS, cookies, static files, SQLite, and deployment.

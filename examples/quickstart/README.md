# Honk Quickstart Example

A minimal realistic Honk application (`app.goose`, ~200 lines) showing:

- Static routes (`GET /`), `:params` (`GET /hello/:name`), `?query` (`?title=`)
- Before-middleware (`X-Example` header) and an auth guard (`/private` → `401`)
- A typed JSON `POST /signup` (`json::Reader`, strict `400` on invalid input)
- The standard transport loop (`honk_wait` → `honk_conn_read` → dispatch →
  `honk_send` → `honk_conn_finish`) with per-request data-stack scopes

It imports the framework as Goose packages (`honk_net`, `honk_ctx` from
`../../src/...`) — the same shape an external user app takes.

## Prerequisites

- Linux with `epoll` (tested on WSL2 Ubuntu 24.04 + native builds)
- The Goose compiler from this repo's pinned commit (`goose_repo/build-linux/goose`)
- `gcc`, `curl`

## Build & run (Release)

```sh
# From the repo root:
/goose_repo/build-linux/goose build examples/quickstart/app.goose -o examples/quickstart/app
./examples/quickstart/app 18080
```

## Try it

```sh
curl http://127.0.0.1:18080/
# Welcome to Honk! Try /hello/ada?title=Dr, /private, /signup

curl "http://127.0.0.1:18080/hello/ada?title=Dr"
# Hello, Dr ada!

curl -i http://127.0.0.1:18080/private
# HTTP/1.1 401 Unauthorized ...

curl http://127.0.0.1:18080/private -H "Authorization: Bearer tok123"
# hello tok123, this route is guarded by middleware

curl -X POST http://127.0.0.1:18080/signup \
  -H "Content-Type: application/json" \
  -d '{"username":"ada","email":"ada@honk.dev","age":36}'
# {"created":true,"username":"ada","age":36}

curl -X POST http://127.0.0.1:18080/signup \
  -H "Content-Type: application/json" -d '{"username":"ada"}'
# Bad Request   (HTTP 400: missing required field)
```

## Sanitizers (ASan + UBSan + LSan)

```sh
./goose_repo/build-linux/goose -o /tmp/qs.c --standalone examples/quickstart/app.goose
gcc -O2 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Isrc/shim -Igoose_repo/src/runtime /tmp/qs.c \
  src/shim/honk_shim.c src/shim/picohttpparser.c \
  -o examples/quickstart/app_asan -lm -pthread -ldl
./examples/quickstart/app_asan 18081
# ... run the curls above against 18081, then shut down cleanly:
curl -X POST http://127.0.0.1:18081/__shutdown
# exit code 0, zero sanitizer findings (LSan runs at clean exit)
```

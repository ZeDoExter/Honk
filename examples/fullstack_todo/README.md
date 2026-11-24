# Fullstack Todo (single Honk binary)

A complete web app in one process: the same binary serves the frontend
(`public/` via kernel `sendfile`) and the JSON API (per-worker SQLite with
WAL + prepared statements). No Node, no bundler, no separate database server.

## Run

```sh
# From the repo root (dev server runs with cwd=app dir):
./honk dev examples/fullstack_todo
# open http://127.0.0.1:18080/
```

```sh
# Production binary (~200 KiB + system libsqlite3):
./honk build examples/fullstack_todo --release
cd examples/fullstack_todo && ./dist/app 8080
```

> The database file `todos.db` is created next to the working directory on
> first run. Delete it to reset the demo.

## API

| Method & path | Body | Response |
|---|---|---|
| `GET /api/todos` | — | `200 [{"id":1,"title":"…","done":false}]` |
| `POST /api/todos` | `{"title":"…"}` | `201 {"id":…,"title":"…","done":false}` / `400` |
| `PATCH /api/todos/:id/toggle` | — | `200 {"ok":true}` / `404` / `400` |
| `DELETE /api/todos/:id` | — | `200 {"ok":true}` / `404` / `400` |

Unknown `GET` routes fall back to `public/index.html` (SPA-style); see
`serve_rel` in `src/honk_static/honk_static.goose`.

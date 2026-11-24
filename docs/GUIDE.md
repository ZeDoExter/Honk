# Honk Guide — Recipes

Copy-pasteable patterns for everyday backends. Every snippet lives inside the
request block (`honk::request(fd, date) { ctx => … };`) — see
[`QUICKSTART.md`](QUICKSTART.md) for the shell. Full reference: [`API.md`](API.md).

> Rule of thumb: blocks are inlined — never `return`/`break` inside them; nest
> `if`/`else` instead. Unstaged requests answer `404` automatically.

## Routing

```goose
if ctx.method == "GET" && ctx.path == "/health" {
    ctx.text(200, "ok");
} else if ctx.method == "GET" {
    // Single segment: /users/:id  (zero-copy view into the request)
    let seg, ok = match_1param(ctx.path, "/users/");
    if ok {
        ctx.params[0] = seg;
        ctx.n_params = 1;
        ctx.text(200, ctx.param_str(0));
    }
} else if ctx.method == "POST" && ctx.path == "/users" {
    ...
}
```

Typed params with validation:

```goose
let id, ok = ctx.param_int(0);   // strict i64, rejects "12x"/overflow
if !ok {
    ctx.json_error(400, "id must be an integer");
} else {
    ...
}
```

Wildcard + traversal guard (`/files/*rest`):

```goose
let rest, ok = ctx.rest("/files/");
if ok && rest.has_dotdot() {
    ctx.text(400, "Bad Request");
} else if ok {
    ctx.text(200, rest);   // serve from your store; rest is zero-copy
}
```

## Query strings

```goose
let name = ctx.query_str_or("name", "World");   // default when absent
let page = ctx.query_int_or("page", 1);         // default when absent/invalid

let q, ok = ctx.query_decoded("q");             // %XX-decoded, + → space
if !ok {
    ctx.text(400, "Bad Request");               // missing key or malformed hex
}
```

## Typed JSON POST validation

```goose
struct Signup { name: const u8[:], has_name: bool, age: i64, has_age: bool }

fn parse_signup(r: json::Reader&, scratch: u8[>..]&, s: Signup&) -> bool {
    json::each_member(r) { key =>
        if key == "name" {
            s.name = json::read_string(r, scratch);   // zero-copy unless escaped
            s.has_name = true;
        } else if key == "age" {
            s.age = json::read_int(r);
            s.has_age = true;
        } else {
            json::skip(r);                            // unknown keys ignored
        }
    };
    if !json::finish(r) { return false; }             // malformed/trailing?
    if !s.has_name || !s.has_age { return false; }    // required?
    return true;
}

// in the route:
var s = Signup { name: "", .. };
var r = json::reader(ctx.body);
if !parse_signup(r, ctx.tmp, s) || s.name.len == 0 {
    ctx.json_error(400, "name (string) and age (int) are required");
} else {
    ctx.res.append("{\"created\":true,\"name\":");
    json::format_string(ctx.res, s.name);             // escaped in place
    ctx.res.append(",\"age\":");
    format(ctx.res, s.age);
    ctx.res.push('}');
    ctx.json_raw(201, ctx.res[..]);
}
```

Dynamic JSON (unknown shape)? Use the DOM instead:

```goose
let d = dom_summary(ctx.body, ctx.dom, ctx.dstr);  // honk_json helper
```

## Bearer auth middleware

```goose
inline fn check_auth(c: Ctx&) -> bool {
    let tok, ok = c.bearer_token();   // `Authorization: Bearer …`, any case
    if !ok {
        c.text(401, "Unauthorized");
        return false;                 // plain fns MAY return; blocks may not
    }
    c.user = tok;                     // decorate ctx for downstream handlers
    c.authed = true;
    return true;
}

// in the block:
if check_auth(ctx) {
    ...protected routes, reading ctx.user...
}
```

## CORS for React / Next.js / Vite

```goose
if ctx.method == "OPTIONS" {
    ctx.cors_preflight();             // 204 + allow-* headers, one line
} else if ... {
    ctx.cors_allow_all();             // or cors_with_origin("https://app.example")
    ...stage the real response...
}
```

## Cookies

```goose
let sess, ok = ctx.cookie("sess");    // zero-copy lookup
if ok { ... }

ctx.set_cookie("sess", token, "Path=/; HttpOnly; Max-Age=3600");
ctx.text(200, "logged in");
```

## Errors, redirects, misc

```goose
ctx.json_error(404, "no such widget");   // {"error":"…"} (escaped) + status
ctx.no_content();                        // empty 204
ctx.redirect("/login");                  // 302 + Location (or 301)
ctx.html(200, "<h1>hi</h1>");
```

## Static files (kernel sendfile)

```goose
import honk_static from "/path/to/Honk/src/honk_static";

// in the block (root is borrowed, never copied):
if (ctx.method == "GET" || ctx.head_only) && try_serve_file(ctx, "public", true) {
    // 200/HEAD staged: MIME + Content-Length + Date, bytes via sendfile.
} else if (ctx.method == "GET" || ctx.head_only)
    && serve_rel(ctx, "public", "index.html", false) {
    // SPA fallback for unknown GET routes.
} else {
    ctx.json_error(404, "not found");
}
```

Traversal (`..`), backslashes, NUL bytes, malformed `%XX`, symlinks, and
non-regular files are rejected (`false` → your `404`); directories resolve
to `index.html` when enabled; other methods stage `405`. Large files stream
without blocking the worker (`EAGAIN` + `EPOLLOUT` resume inside the shim).

## SQLite (opt-in, per-worker WAL)

Add the shim + lib to your `.build` (only SQLite apps pay):

```goose
// myapp.build
c_sources = ["<honk>/src/shim/honk_shim.c", "<honk>/src/shim/picohttpparser.c",
             "<honk>/src/shim/honk_sqlite_shim.c"];
c_include = ["<honk>/src/shim"];
c_libs = ["sqlite3"];   // needs libsqlite3-dev (or ~/.local/sqlite3)
```

Open one connection per worker and capture it (with prepared statements) in
the request block — the worker-state pattern:

```goose
import honk_sqlite from "/path/to/Honk/src/honk_sqlite";

thread_fn worker(port: i32) {
    honk::listen_or_abort(port);
    let db, ok = db_open("app.db");
    guard ok else { abort("db_open failed"); }
    guard db_enable_wal(db) else { abort("wal failed"); }  // WAL+NORMAL+5s busy
    let st_get, gok = db_prepare(db, "SELECT name FROM users WHERE id = ?1;");
    guard gok else { abort("prepare failed"); }
    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.method == "GET" && ctx.path == "/user" {
                let id = ctx.query_int_or("id", -1);
                if id > 0 && bind_int(st_get, 1, id) && stmt_step(st_get) == ROW {
                    let nm, nok = col_text(st_get, 0, ctx.tmp);
                    stmt_reset(st_get);
                    if nok {
                        ctx.res.append("{\"name\":");
                        json::format_string(ctx.res, nm);
                        ctx.res.push('}');
                        ctx.json_raw(200, ctx.res[..]);
                    } else {
                        ctx.json_error(500, "read failed");
                    }
                } else {
                    stmt_reset(st_get);   // reset on EVERY path: reuse invariant
                    ctx.json_error(404, "not found");
                }
            }
        };
    };
    stmt_finalize(st_get);
    db_close(db);
}
```

Rules: run schema DDL once in `main` (concurrent DDL can abort); always
`stmt_reset` after stepping (even on errors); `bind_text` (transient) by
default, `bind_text_static` only for static/request lifetimes; call
`db_shutdown()` in `main` after all workers join. Multi-worker WAL needs a
POSIX filesystem (not a Windows/9P mount) for the `-shm` file.

## Production deployment

- **Binary**: `./honk build my-api --release` → `my-api/dist/main`. Ship it as-is
  (libc + pthreads only, ~150 KiB). Run `./main 8080`.
- **Workers**: spawn N `thread_fn` workers (kernel `SO_REUSEPORT` balances);
  see `src/server.goose` for the pinned multi-worker pattern.
- **Reverse proxy** (TLS): terminate TLS in nginx/Caddy and proxy plain
  HTTP/1.1 to Honk (static assets are served natively via `sendfile`). Example:
  ```nginx
  server {
      listen 443 ssl;  # + certs
      location / { proxy_pass http://127.0.0.1:8080; }
  }
  ```
- **systemd**: `ExecStart=/opt/my-api/main 8080`, `Restart=always`. Honk has no
  graceful-drain hook yet — `SIGTERM` stops immediately; keep a `POST
  /__shutdown`-style route calling `honk_request_stop()` if you want clean
  in-flight draining before deploys.
- **Docker**: copy the repo `Dockerfile` pattern (multi-stage, Goose pinned,
  slim runtime).

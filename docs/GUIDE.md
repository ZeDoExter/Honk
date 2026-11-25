# Honk Guide — Recipes

Copy-pasteable patterns for everyday backends. Every snippet runs inside
`honk::listen(port) { app => … };` after a single `import honk from "<honk>/src";`
— see [`QUICKSTART.md`](QUICKSTART.md) for scaffolding and [`API.md`](API.md)
for the complete reference.

> Rule of thumb: blocks (`{ app => … }`) are inlined — never `return`/`break`
> inside them; nest `if`/`else` instead (plain `fn`s called from a block *may*
> `return`). First matching route wins; matched paths with the wrong method
> answer `405`, everything else `404`.

## Imports

Apps import the `honk` barrel once (`./honk new` writes the path for you):

```goose
import honk from "../../src";                 // listen, App DSL, Ctx, static
import honk.honk_sqlite.honk_sqlite;          // opt-in: only if you use SQLite
```

## Routing

```goose
honk::listen(18080) { app =>
    // Static literals (200 OK; GET + HEAD):
    app.get("/health", "ok");
    app.get_json_raw("/ready", "{\"ready\":true}");

    // Block routes: get, post, put, patch, delete
    app.post("/ping") { app.ok("pong"); };

    // Single string segment (/users/ada -> "ada", zero-copy slice):
    app.get_param("/users/:name") { name => app.ok(name); };

    // Typed i64 segment (auto-400 JSON error if non-integer or overflowing):
    app.get_int("/items/:id") { id =>
        app.json() { j => j.int("id", id); };
    };
    app.patch_int("/items/:id") { id => app.ok_json(); };
    app.delete_int("/items/:id") { id => app.no_content(); };

    // Two segments (/orgs/goose/repos/honk):
    app.get2("/orgs/:org/repos/:repo") { org, repo =>
        app.json() { j => j.str("org", org); j.str("repo", repo); };
    };

    // Wildcard tail (/files/a/b.txt -> "a/b.txt") + traversal guard:
    app.get_wild("/files/*") { rest =>
        if honk::has_dotdot(rest) {
            app.text(400, "Bad Request");
        } else {
            app.ok(rest);
        }
    };
};
```

## Query strings

```goose
let name = app.query_str_or("name", "World");   // default when absent
let page = app.query_int_or("page", 1);         // default when absent/invalid

let q, ok = app.query_decoded("q");             // %XX-decoded, + -> space
if !ok {
    app.text(400, "Bad Request");               // missing key or malformed hex
}
```

## JSON responses & body extraction

Emit JSON without manual `\"` escaping or comma tracking via `app.json()` (`200`)
and `app.created_json()` (`201`):

```goose
app.post("/signup") {
    app.require_str("username") { u =>          // auto-400 if malformed/missing/empty
        app.require_str("email") { e =>
            let age, has_age = app.body_int("age");
            let newsletter, _ = app.body_bool("newsletter");
            app.created_json() { j =>
                j.jbool("created", true);
                j.str("username", u);
                j.str("email", e);
                j.jbool("newsletter", newsletter);
                if has_age { j.int("age", age); }
            };
        };
    };
};
```

`body_str`, `body_int`, `body_bool`, and `require_str` parse `app.body` at most
once per request into `app.dom`/`app.dstr` (reset automatically after each request).

Need maximum hot-path throughput with zero DOM nodes? Stream directly with
`json::Reader`:

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
            json::skip(r);
        }
    };
    return json::finish(r) && s.has_name && s.has_age && s.name.len > 0;
}
```

## Bearer auth guard

```goose
inline fn check_auth(app: honk::Ctx&) -> bool {
    let tok, ok = app.bearer_token();   // `Authorization: Bearer …`, any case
    if !ok {
        app.text(401, "Unauthorized");
        app.handled = true;             // claim request so later routes/405 skip it
        return false;                   // plain fns MAY return; blocks may not
    }
    app.user = tok;
    app.authed = true;
    return true;
}

// inside honk::listen:
app.get("/private") {
    if check_auth(app) {
        app.ok(app.user);
    }
};
```

## CORS for React / Next.js / Vite

```goose
honk::listen(18080) { app =>
    if app.method == "OPTIONS" {
        app.cors_preflight();           // 204 + allow-* headers
        app.handled = true;             // skip route matching / 405
    } else {
        app.cors_allow_all();           // or app.cors_with_origin("https://app.example")
    }
    app.get("/api/items") { app.ok_json(); };
};
```

## Cookies, errors, redirects

```goose
let sess, ok = app.cookie("sess");      // zero-copy lookup
app.set_cookie("sess", token, "Path=/; HttpOnly; Max-Age=3600");

app.json_error(404, "no such widget");  // {"error":"…"} (escaped) + status
app.ok_json();                          // 200 {"ok":true}
app.no_content();                       // empty 204
app.redirect("/login");                 // 302 + Location (or 301)
app.html(200, "<h1>hi</h1>");
```

## Static files & SPAs (kernel `sendfile`)

```goose
honk::listen(18080) { app =>
    app.get("/api/health", "ok");
    app.static_dir("/", "public");      // GET/HEAD files + directory index.html
    app.get_wild("/*") { _rest =>       // SPA fallback for client-side routes
        serve_rel(app, "public", "index.html", false);
    };
};
```

Traversal (`..`), backslashes, NUL bytes, malformed `%XX`, symlinks, and
non-regular files are rejected; non-`GET`/`HEAD` requests to mounted paths
answer `405`. Large files stream directly from page cache via `sendfile`
(`EAGAIN` + `EPOLLOUT` resume inside the C shim).

## SQLite (opt-in, WAL + one-line JSON queries)

Add the SQLite shim and `-lsqlite3` to your `.build` file (apps without it do
not link `libsqlite3`):

```goose
// main.build
c_sources = ["<honk>/src/shim/honk_shim.c", "<honk>/src/shim/picohttpparser.c",
             "<honk>/src/shim/honk_sqlite_shim.c"];
c_include = ["<honk>/src/shim"];
c_libs = ["sqlite3"];   // needs libsqlite3-dev (or ~/.local/sqlite3 via ./honk)
```

Stream query results straight into JSON responses with `sql_json` /
`sql_json_one` / `sql_json_one_text`, and run parameterized mutations with
`insert_text` / `run_int`:

```goose
import std;
import honk from "../../src";
import honk.honk_sqlite.honk_sqlite;

fn main() {
    let db, ok = db_open("todos.db");
    guard ok && db_enable_wal(db) else { abort("db setup failed"); }
    guard db_exec(db, "CREATE TABLE IF NOT EXISTS todos(id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0);") else { abort("ddl failed"); }

    honk::listen(18080) { app =>
        app.get("/api/todos") {
            app.sql_json(db, "SELECT id, title, done FROM todos ORDER BY id;");
        };
        app.get_int("/api/todos/:id") { id =>
            app.sql_json_one(db, "SELECT id, title, done FROM todos WHERE id = ?1;", id);
        };
        app.post("/api/todos") {
            app.require_str("title") { title =>
                let id, iok = insert_text(db, "INSERT INTO todos(title) VALUES (?1);", title);
                if !iok {
                    app.json_error(500, "insert failed");
                } else {
                    app.created_json() { j => j.int("id", id); j.str("title", title); };
                }
            };
        };
        app.delete_int("/api/todos/:id") { id =>
            let n, dok = run_int(db, "DELETE FROM todos WHERE id = ?1;", id);
            if !dok { app.json_error(500, "delete failed"); }
            else if n == 0 { app.json_error(404, "not found"); }
            else { app.ok_json(); }
        };
    };
    db_close(db);
    db_shutdown();
}
```

Need long-lived prepared statements across millions of requests or custom column
reshaping (e.g. `0/1` → JSON `bool`, as in `examples/fullstack_todo/app.goose`)?
Use `db_prepare` + `bind_*` + `stmt_step` + `col_*` + `stmt_reset` +
`stmt_finalize`.

SQLite rules:
- Run schema DDL once in `main` before forking or spawning workers (concurrent DDL can abort with `SQLITE_SCHEMA`).
- **Multi-worker SQLite (`HONK_WORKERS`)**: SQLite handles must never cross `fork()` (Honk's runtime guard aborts if you try). Close your setup DDL handle first, call `honk::workers_env()` (or `honk::workers(n)`), then open each worker's own WAL handle:
  ```goose
  { let mdb, _ = db_open("todos.db"); db_enable_wal(mdb); db_exec(mdb, "CREATE TABLE ..."); db_close(mdb); }
  honk::workers_env();                       // forks here when $HONK_WORKERS > 1
  let db, _ = db_open("todos.db");           // independent WAL handle per worker
  db_enable_wal(db);
  honk::listen(18080) { app => … };          // drains on SIGTERM/SIGINT, joins children
  db_close(db);
  db_shutdown();
  ```
- Always call `stmt_reset(st)` on *every* exit path when stepping a reusable `Stmt`.
- Multi-worker WAL requires a POSIX filesystem (e.g. `/tmp` or native Linux ext4, not a Windows/9P mount) for the `-shm` file.

## Multi-worker scaling & production deployment

- **Zero-code multi-worker (`$HONK_WORKERS`)**: `honk::listen(port)` runs a
  single process by default and scales to `N` `SO_REUSEPORT` worker processes
  with `HONK_WORKERS=4` or `HONK_WORKERS=auto` (reads `sched_getaffinity`, safe
  in Docker/cgroups/`taskset`), or in code via `honk::listen_workers(port, n)`
  (`0` = auto). Need thread workers with explicit CPU pinning instead? Pair
  `thread_fn` + `honk::listen_cfg_or_abort` + `honk::request_app`.
- **Graceful shutdown (`SIGINT` / `SIGTERM`)**: `Ctrl-C`, `systemctl stop`, and
  `docker stop` close the listening socket immediately, finish the current
  turn's requests, forward `SIGTERM` to any forked workers, and flush queued
  outbound bytes (`pending_tx` / `sendfile`) for up to `2s` before exiting `0`
  (a second `SIGINT` force-exits immediately).
- **Binary**: `./honk build my-api --release` → `my-api/dist/main` (~150 KiB,
  libc + pthreads only). Run `HONK_WORKERS=auto ./main 8080`.
- **Reverse proxy (TLS)**: terminate TLS in nginx/Caddy and proxy HTTP/1.1 to
  Honk:
  ```nginx
  server {
      listen 443 ssl;  # + certs
      location / { proxy_pass http://127.0.0.1:8080; }
  }
  ```
- **systemd**: `ExecStart=/opt/my-api/main 8080`, `Environment=HONK_WORKERS=auto`,
  `Restart=always`. `SIGTERM` drains in-flight responses cleanly out of the box.
- **Docker**: copy the repo `Dockerfile` pattern (multi-stage, pinned Goose, slim runtime).

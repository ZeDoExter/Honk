// honk_app.goose -- Honk concise route & JSON API over honk::serve (`honk::` namespace).
//
//   honk::listen(18080) { app =>
//       app.get("/health", "ok");
//       app.get("/users/:name") { app.ok(app.param("name")); };
//       app.get("/files/*") { app.ok(app.tail); };
//   };
//
// Unified pattern routing: `app.get/post/put/patch/delete` handle static
// paths, up to 4 `:param` segments (with literal suffixes like
// `/todos/:id/toggle`), and trailing `/*` wildcards (`app.tail`). Static
// literals fold at compile time to a single slice comparison; everything
// monomorphizes into the worker loop with zero closure allocations.

namespace honk;

import std;
import os;
import json;
import src.honk_net.honk_net;
import src.honk_ctx.honk_ctx;
import src.honk_serve.honk_serve;

// CLI port helper: parses argv[1] when in 1..65535, else default_port.
fn arg_port(default_port: i32) -> i32 {
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok && v >= 1 && v <= 65535 { return v as! i32; }
    }
    return default_port;
}

// One request through the App DSL: runs F, then 405 when a path matched but
// nothing handled (the turn 404s anything still unstaged).
inline fn app_run<F>(ctx: Ctx&) {
    F(ctx);
    if !ctx.handled && ctx.path_matched {
        ctx.text(405, "Method Not Allowed");
    }
}

// Per-request App scope over a turn: use inside multi-worker `thread_fn`s.
inline fn request_app<F>(fd: i32, date: const u8[:]) {
    request(fd, date) { ctx =>
        app_run(ctx) { c => F(c); };
    };
}

// Pre-fork `n` SO_REUSEPORT worker processes (0 = auto CPU count, 1..64).
// Call before per-worker setup like `db_open()`; listen() joins children.
fn workers(n: i32) -> i32 {
    return honk_fork_workers(n);
}

// Pre-fork worker processes from $HONK_WORKERS (defaults to 1 when unset).
fn workers_env() -> i32 {
    return honk_fork_env();
}

// Server on `main`: 1 worker by default, or N SO_REUSEPORT workers via
// $HONK_WORKERS (or a prior honk::workers() call). Drains cleanly on
// SIGINT, SIGTERM, or honk_request_stop() so LSan and destructors run.
fn listen<F>(port: i32) {
    honk_fork_env();
    honk_set_timeouts(30000, 10000);
    guard honk_worker_init(port) == 0 else { abort("honk_worker_init failed"); }
    serve() { fd, date =>
        request_app(fd, date) { app => F(app); };
    };
    honk_fork_join();
}

// Explicit multi-worker variant of listen() (n = 0 for auto CPU count, 1..64).
fn listen_workers<F>(port: i32, n: i32) {
    honk_fork_workers(n);
    honk_set_timeouts(30000, 10000);
    guard honk_worker_init(port) == 0 else { abort("honk_worker_init failed"); }
    serve() { fd, date =>
        request_app(fd, date) { app => F(app); };
    };
    honk_fork_join();
}

// listen() with full Config (timeouts, worker id, CPU pin).
fn listen_cfg<F>(cfg: Config&) {
    listen_cfg_or_abort(cfg);
    serve() { fd, date =>
        request_app(fd, date) { app => F(app); };
    };
    honk_fork_join();
}

// --- unified zero-copy route pattern matcher ---

inline fn has_route_meta(pat: const u8[:]) -> bool {
    for b in pat {
        if b == ':' || b == '*' { return true; }
    }
    return false;
}

// Segment walker for patterns containing `:param` (up to 4, suffixes allowed)
// or a trailing `/*` wildcard. Commits into `app` only when the full pattern
// matches `app.path`.
fn match_route_dyn(app: Ctx&, pat: const u8[:]) -> bool {
    let path = app.path;
    if pat.len == 0 || pat[0] != '/' || path.len == 0 || path[0] != '/' {
        return false;
    }
    var pvals: const u8[:][4] = [path[..0]; 4];
    var pnames: const u8[:][4] = [pat[..0]; 4];
    var np: i64 = 0;

    var pi: i64 = 1;
    var xi: i64 = 1;
    while pi <= pat.len {
        var pend = pat.len;
        var k = pi;
        while k < pat.len {
            if pat[k] == '/' { pend = k; break; }
            k++;
        }
        let pseg = pat[pi..pend];

        if pseg == "*" && pend == pat.len {
            if xi >= path.len { return false; }
            let rem = path[xi..];
            if np < 4 {
                pvals[np] = rem;
                pnames[np] = pseg;
                np++;
            }
            for idx in np {
                app.params[idx] = pvals[idx];
                app.param_names[idx] = pnames[idx];
            }
            app.n_params = np;
            app.tail = rem;
            return true;
        }

        if xi > path.len { return false; }
        var xend = path.len;
        var m = xi;
        while m < path.len {
            if path[m] == '/' { xend = m; break; }
            m++;
        }
        let xseg = path[xi..xend];

        if pseg.len > 1 && pseg[0] == ':' {
            if xseg.len == 0 { return false; }
            if np < 4 {
                pvals[np] = xseg;
                pnames[np] = pseg[1..];
                np++;
            }
        } else if pseg != xseg {
            return false;
        }

        let pat_done = pend == pat.len;
        let path_done = xend == path.len;
        if pat_done && path_done {
            for idx in np {
                app.params[idx] = pvals[idx];
                app.param_names[idx] = pnames[idx];
            }
            app.n_params = np;
            app.tail = path[..0];
            return true;
        }
        if pat_done != path_done { return false; }
        pi = pend + 1;
        xi = xend + 1;
    }
    return false;
}

inline fn match_route(app: Ctx&, route: const u8[:]) -> bool {
    if !has_route_meta(route) {
        return app.path == route;
    }
    return match_route_dyn(app, route);
}

// --- static literal routes (default 200 OK) ---

inline fn get_text(app: Ctx&, route: const u8[:], body: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        app.text(200, body);
        app.handled = true;
    }
}

inline fn get_json_raw(app: Ctx&, route: const u8[:], body: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        app.json_raw(200, body);
        app.handled = true;
    }
}

// --- unified pattern routes (static, `:param` + suffixes, `/*` wildcard) ---

inline fn get<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        F();
        app.handled = true;
    }
}

// Static-body overload: app.get("/health", "ok").
inline fn get(app: Ctx&, route: const u8[:], body: const u8[:]) {
    app.get_text(route, body);
}

inline fn post<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "POST" && ok {
        F();
        app.handled = true;
    }
}

inline fn put<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "PUT" && ok {
        F();
        app.handled = true;
    }
}

inline fn patch<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "PATCH" && ok {
        F();
        app.handled = true;
    }
}

inline fn delete<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "DELETE" && ok {
        F();
        app.handled = true;
    }
}

// --- typed i64 param routes (auto-400 on non-int; suffixes like /todos/:id/toggle OK) ---

inline fn get_int<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        let v, vok = app.param_int(0);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

inline fn post_int<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "POST" && ok {
        let v, vok = app.param_int(0);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

inline fn put_int<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "PUT" && ok {
        let v, vok = app.param_int(0);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

inline fn patch_int<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "PATCH" && ok {
        let v, vok = app.param_int(0);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

inline fn delete_int<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "DELETE" && ok {
        let v, vok = app.param_int(0);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

// --- param-passing aliases (kept for compatibility alongside app.param/tail) ---

inline fn get_param<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        F(app.param_str(0));
        app.handled = true;
    }
}

inline fn get2<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        F(app.param_str(0), app.param_str(1));
        app.handled = true;
    }
}

inline fn get_wild<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if (app.method == "GET" || app.head_only) && ok {
        F(app.tail);
        app.handled = true;
    }
}

inline fn patch_wild<F>(app: Ctx&, prefix: const u8[:]) {
    if app.handled { return; }
    let rest, ok = app.rest(prefix);
    if ok { app.path_matched = true; }
    if app.method == "PATCH" && ok {
        app.tail = rest;
        F(rest);
        app.handled = true;
    }
}

// --- short responses (default 200 OK) ---

inline fn ok(app: Ctx&, body: const u8[:]) {
    app.text(200, body);
}

inline fn ok_json(app: Ctx&) {
    app.json_raw(200, "{\"ok\":true}");
}

// --- streaming JSON writer over ctx.res (zero-copy, overloaded j.set) ---

struct JWriter { out: u8[>..]&, first: bool }

inline fn str(j: JWriter&, key: const u8[:], val: const u8[:]) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    json::format_string(j.out, val);
}

inline fn int(j: JWriter&, key: const u8[:], val: i64) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    json::format_int(j.out, val);
}

inline fn num(j: JWriter&, key: const u8[:], val: f64) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    json::format_number(j.out, val);
}

inline fn jbool(j: JWriter&, key: const u8[:], val: bool) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    json::format_bool(j.out, val);
}

inline fn jnull(j: JWriter&, key: const u8[:]) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    j.out.append("null");
}

inline fn raw(j: JWriter&, key: const u8[:], fragment: const u8[:]) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    j.out.append(fragment);
}

// Type-overloaded `j.set(key, val)` for str / i64 / f64 / bool.
inline fn set(j: JWriter&, key: const u8[:], val: const u8[:]) { j.str(key, val); }
inline fn set(j: JWriter&, key: const u8[:], val: i64) { j.int(key, val); }
inline fn set(j: JWriter&, key: const u8[:], val: f64) { j.num(key, val); }
inline fn set(j: JWriter&, key: const u8[:], val: bool) { j.jbool(key, val); }

inline fn json_run<F>(w: JWriter&) {
    w.out.push('{');
    F(w);
    w.out.push('}');
}

inline fn json<F>(app: Ctx&) {
    var w = JWriter { out: app.res, first: true };
    let start = app.res.len;
    json_run(w) { j => F(j); };
    app.json_raw(200, app.res[start..]);
}

inline fn created_json<F>(app: Ctx&) {
    var w = JWriter { out: app.res, first: true };
    let start = app.res.len;
    json_run(w) { j => F(j); };
    app.json_raw(201, app.res[start..]);
}

// --- request-body field extractors (DOM parsed once per request) ---

inline fn body_root(app: Ctx&) -> json::Node?, bool {
    if !app.dom_ready {
        app.dom_ready = true;
        let r, _e = json::parse(app.body, app.dom, app.dstr);
        if r {
            app.dom_root .= r;
            app.dom_ok = true;
        }
    }
    if !app.dom_ok { return null, false; }
    return app.dom_root, true;
}

inline fn body_str(app: Ctx&, key: const u8[:]) -> const u8[:], bool {
    let root, ok = body_root(app);
    if !ok { return "", false; }
    return json::as_string(json::member(root, key));
}

inline fn body_int(app: Ctx&, key: const u8[:]) -> i64, bool {
    let root, ok = body_root(app);
    if !ok { return 0, false; }
    return json::as_i64(json::member(root, key));
}

inline fn body_bool(app: Ctx&, key: const u8[:]) -> bool, bool {
    let root, ok = body_root(app);
    if !ok { return false, false; }
    return json::as_bool(json::member(root, key));
}

inline fn require_str<F>(app: Ctx&, key: const u8[:]) {
    let v, ok = app.body_str(key);
    if !ok || v.len == 0 {
        app.json_error(400, "invalid or missing field");
    } else {
        F(v);
    }
}

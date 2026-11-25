// honk_app.goose -- Honk concise route, lifecycle, JSON & validation API (`honk::`).
//
//   honk::listen(18080) { app =>
//       app.get("/health", "ok");
//       app.get("/users/:name") { app.ok(app.param("name")); };
//       app.get("/files/*") { app.ok(app.tail); };
//   };
//
// Unified pattern routing, nestable `app.group("/api")`, one-line `cors()` /
// `bearer()` / `server_timing()` / `json_errors()`, nested `JWriter` + `JArray`
// streaming, and field-named `require_*` validators. Every helper is `inline fn`
// so unused features compile away completely (zero binary bloat).

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

// Finalize unstaged 405/404 responses (respects json_errors() mode).
inline fn resolve_unhandled(ctx: Ctx&) {
    if !ctx.handled && ctx.path_matched && !ctx.responded {
        if ctx.json_err_mode {
            ctx.json_error(405, "method not allowed");
        } else {
            ctx.text(405, "Method Not Allowed");
        }
    } else if !ctx.responded {
        if ctx.json_err_mode {
            ctx.json_error(404, "not found");
        } else {
            ctx.text(404, "Not Found");
        }
    }
}

// Append `Server-Timing: honk;dur=<ms>.<us>` when `app.server_timing()` was enabled.
inline fn emit_server_timing(ctx: Ctx&) {
    if ctx.t0_ns <= 0 { return; }
    let dt_ns = honk_now_ns() - ctx.t0_ns;
    let us = if dt_ns > 0 { dt_ns / 1000 } else { 0 };
    let ms = us / 1000;
    let frac = us % 1000;
    let start = ctx.tmp.len;
    ctx.tmp.append("honk;dur=");
    format(ctx.tmp, ms);
    ctx.tmp.push('.');
    if frac < 100 { ctx.tmp.push('0'); }
    if frac < 10 { ctx.tmp.push('0'); }
    format(ctx.tmp, frac);
    ctx.set_header("Server-Timing", ctx.tmp[start..]);
    ctx.t0_ns = 0;
}

// One request through the App DSL: runs F, resolves 405/404, emits Server-Timing.
inline fn app_run<F>(ctx: Ctx&) {
    F(ctx);
    resolve_unhandled(ctx);
    emit_server_timing(ctx);
}

// Per-request App scope over a turn: use inside multi-worker `thread_fn`s.
inline fn request_app<F>(fd: i32, date: const u8[:]) {
    request(fd, date) { ctx =>
        app_run(ctx) { c => F(c); };
    };
}

// Pre-fork `n` SO_REUSEPORT worker processes (0 = auto CPU count, 1..64).
fn workers(n: i32) -> i32 {
    return honk_fork_workers(n);
}

// Pre-fork worker processes from $HONK_WORKERS (defaults to 1 when unset).
fn workers_env() -> i32 {
    return honk_fork_env();
}

// Server on `main`: 1 worker by default, or N SO_REUSEPORT workers via
// $HONK_WORKERS (or a prior honk::workers() call).
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

// --- lifecycle, groups, and one-line guards ---

// Switch default 404 / 405 / 401 guard responses to application/json {"error":...}.
inline fn json_errors(app: Ctx&) {
    app.json_err_mode = true;
}

// Measure request duration and attach `Server-Timing: honk;dur=<ms>`.
inline fn server_timing(app: Ctx&) {
    if app.t0_ns == 0 {
        app.t0_ns = honk_now_ns();
    }
}

// Post-route hook: finalizes 404/405 first so `app.status` reflects the final code.
inline fn after<F>(app: Ctx&) {
    resolve_unhandled(app);
    F();
}

// One-line CORS (`*` allow-all + automatic `204` `OPTIONS` preflight).
inline fn cors(app: Ctx&) {
    if app.handled { return; }
    if app.method == "OPTIONS" {
        app.cors_preflight();
        app.handled = true;
    } else {
        app.cors_allow_all();
    }
}

// Fixed-origin variant of `app.cors("https://app.example")`.
inline fn cors(app: Ctx&, origin: const u8[:]) {
    if app.handled { return; }
    app.cors_with_origin(origin);
    if app.method == "OPTIONS" {
        app.no_content();
        app.handled = true;
    }
}

// One-line Bearer auth guard: runs `F(token)` on valid Bearer header, else
// stages `401` and marks `app.handled = true` so downstream routes/405 skip it.
inline fn bearer<F>(app: Ctx&) {
    if app.handled { return; }
    let tok, ok = app.bearer_token();
    if !ok {
        if app.json_err_mode {
            app.json_error(401, "unauthorized");
        } else {
            app.text(401, "Unauthorized");
        }
        app.handled = true;
    } else {
        app.user = tok;
        app.authed = true;
        F(tok);
    }
}

// Nestable zero-alloc route prefix group: `app.group("/api/v1") { ... }`.
// Skips the entire block in one branch when `app.path` does not start with `prefix`.
inline fn group<F>(app: Ctx&, prefix: const u8[:]) {
    if app.handled { return; }
    var plen = prefix.len;
    while plen > 1 && prefix[plen - 1] == '/' { plen--; }
    let p = prefix[..plen];
    if p.len == 0 || p[0] != '/' { return; }
    if p == "/" {
        F();
        return;
    }
    let saved = app.path;
    if saved.len < p.len || saved[..p.len] != p { return; }
    if saved.len > p.len && saved[p.len] != '/' { return; }
    // Both branches slice `saved` (same borrow root `rx_buf`): saved[..1] == "/".
    app.path = if saved.len == p.len { saved[..1] } else { saved[p.len..] };
    F();
    app.path = saved;
}

// --- unified zero-copy route pattern matcher ---

inline fn has_route_meta(pat: const u8[:]) -> bool {
    for b in pat {
        if b == ':' || b == '*' { return true; }
    }
    return false;
}

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

inline fn options<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "OPTIONS" && ok {
        F();
        app.handled = true;
    }
}

inline fn all<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    if match_route(app, route) {
        app.path_matched = true;
        F();
        app.handled = true;
    }
}

// --- typed i64 param routes (auto-400 on non-int; suffixes OK) ---

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

// --- param-passing compatibility aliases ---

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

// --- streaming JSON writer & array writer over ctx.res (nested, zero-copy) ---

struct JWriter { out: u8[>..]&, first: bool }
struct JArray { out: u8[>..]&, first: bool }

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

inline fn jarr_run<F>(a: JArray&) {
    a.out.push('[');
    F(a);
    a.out.push(']');
}

// Nested object field: `j.obj("user") { u => u.set("name", "Ada"); };`
inline fn obj<F>(j: JWriter&, key: const u8[:]) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    var child = JWriter { out: j.out, first: true };
    json_run(child) { c => F(c); };
}

// Nested array field: `j.arr("tags") { a => a.add("goose"); a.add("honk"); };`
inline fn arr<F>(j: JWriter&, key: const u8[:]) {
    if !j.first { j.out.push(','); }
    j.first = false;
    json::format_key(j.out, key);
    var child = JArray { out: j.out, first: true };
    jarr_run(child) { c => F(c); };
}

// Type-overloaded `a.add(val)` on `JArray&` + nested `a.obj` / `a.arr`.
inline fn add(a: JArray&, val: const u8[:]) {
    if !a.first { a.out.push(','); }
    a.first = false;
    json::format_string(a.out, val);
}

inline fn add(a: JArray&, val: i64) {
    if !a.first { a.out.push(','); }
    a.first = false;
    json::format_int(a.out, val);
}

inline fn add(a: JArray&, val: f64) {
    if !a.first { a.out.push(','); }
    a.first = false;
    json::format_number(a.out, val);
}

inline fn add(a: JArray&, val: bool) {
    if !a.first { a.out.push(','); }
    a.first = false;
    json::format_bool(a.out, val);
}

inline fn jnull(a: JArray&) {
    if !a.first { a.out.push(','); }
    a.first = false;
    a.out.append("null");
}

inline fn raw(a: JArray&, fragment: const u8[:]) {
    if !a.first { a.out.push(','); }
    a.first = false;
    a.out.append(fragment);
}

inline fn obj<F>(a: JArray&) {
    if !a.first { a.out.push(','); }
    a.first = false;
    var child = JWriter { out: a.out, first: true };
    json_run(child) { c => F(c); };
}

inline fn arr<F>(a: JArray&) {
    if !a.first { a.out.push(','); }
    a.first = false;
    var child = JArray { out: a.out, first: true };
    jarr_run(child) { c => F(c); };
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

// Top-level `200 application/json` array response: `app.json_list() { a => ... };`
inline fn json_list<F>(app: Ctx&) {
    var a = JArray { out: app.res, first: true };
    let start = app.res.len;
    jarr_run(a) { arr_w => F(arr_w); };
    app.json_raw(200, app.res[start..]);
}

// --- request-body field extractors & named-field validators ---

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

inline fn field_error(app: Ctx&, prefix: const u8[:], key: const u8[:]) {
    let start = app.tmp.len;
    app.tmp.append(prefix);
    app.tmp.append(key);
    app.json_error(400, app.tmp[start..]);
}

// Required non-empty string field -> `F(val)`, else `400 {"error":"invalid or missing field: <key>"}`.
inline fn require_str<F>(app: Ctx&, key: const u8[:]) {
    let v, ok = app.body_str(key);
    if !ok || v.len == 0 {
        field_error(app, "invalid or missing field: ", key);
    } else {
        F(v);
    }
}

// Required string field with byte-length bounds `min_len..=max_len`.
inline fn require_str_len<F>(app: Ctx&, key: const u8[:], min_len: i64, max_len: i64) {
    let v, ok = app.body_str(key);
    if !ok || v.len < min_len || v.len > max_len {
        field_error(app, "invalid length for field: ", key);
    } else {
        F(v);
    }
}

// Required integer field -> `F(val)`, else `400 {"error":"invalid or missing field: <key>"}`.
inline fn require_int<F>(app: Ctx&, key: const u8[:]) {
    let v, ok = app.body_int(key);
    if !ok {
        field_error(app, "invalid or missing field: ", key);
    } else {
        F(v);
    }
}

// Required integer field clamped to `min_v..=max_v`.
inline fn require_int_range<F>(app: Ctx&, key: const u8[:], min_v: i64, max_v: i64) {
    let v, ok = app.body_int(key);
    if !ok {
        field_error(app, "invalid or missing field: ", key);
    } else if v < min_v || v > max_v {
        field_error(app, "out of range: ", key);
    } else {
        F(v);
    }
}

// Required boolean field -> `F(val)`, else `400 {"error":"invalid or missing field: <key>"}`.
inline fn require_bool<F>(app: Ctx&, key: const u8[:]) {
    let v, ok = app.body_bool(key);
    if !ok {
        field_error(app, "invalid or missing field: ", key);
    } else {
        F(v);
    }
}

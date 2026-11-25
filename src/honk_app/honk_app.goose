// honk_app.goose -- Honk concise route & JSON API over honk::serve (`honk::` namespace).
//
//   honk::listen(18080) { app =>
//       app.get("/health", "ok");
//       app.get_param("/users/:name") { name => app.ok(name); };
//       app.get_wild("/files/*") { path => app.ok(path); };
//   };
//
// First-match-wins: every route runs its block at most once per request; an
// unhandled request with a path match answers 405, otherwise the turn 404s.
// `app` is the per-request Ctx (named for readability): everything is `inline
// fn`, so user dispatch monomorphizes into the worker loop with zero closure
// allocations (verified: no App/route `_g` defs in generated C).
// Blocks capture the outer `app` by reference; never `return`/`break` inside.

namespace honk;

import std;
import json;
import honk_ctx.honk_ctx;
import honk_serve.honk_serve;

// One request through the App DSL: runs F, then 405 when a path matched but
// nothing handled (the turn 404s anything still unstaged).
inline fn app_run<F>(ctx: Ctx&) {
    F(ctx);
    if !ctx.handled && ctx.path_matched {
        ctx.text(405, "Method Not Allowed");
    }
}

// Per-request App scope over a turn: use inside multi-worker `thread_fn`s
// with a shared named routes fn (see GUIDE); single-worker apps prefer
// honk::listen below.
inline fn request_app<F>(fd: i32, date: const u8[:]) {
    request(fd, date) { ctx =>
        app_run(ctx) { c => F(c); };
    };
}

// Single-worker server on the calling thread (plain `main`, no threads).
// Returns after a clean shutdown (honk_request_stop), so LSan runs at exit.
fn listen<F>(port: i32) {
    listen_or_abort(port);
    serve() { fd, date =>
        request_app(fd, date) { app => F(app); };
    };
}

// listen() with full Config (timeouts, worker id, CPU pin).
fn listen_cfg<F>(cfg: Config&) {
    listen_cfg_or_abort(cfg);
    serve() { fd, date =>
        request_app(fd, date) { app => F(app); };
    };
}

// --- static literal routes (default 200 OK) ---

inline fn get_text(app: Ctx&, path: const u8[:], body: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only)
        && app.path == path {
        app.text(200, body);
        app.handled = true;
    }
}

inline fn get_json_raw(app: Ctx&, path: const u8[:], body: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only)
        && app.path == path {
        app.json_raw(200, body);
        app.handled = true;
    }
}

// --- block routes (first-match-wins; blocks capture `app`) ---

inline fn get<F>(app: Ctx&, path: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only)
        && app.path == path {
        F();
        app.handled = true;
    }
}

// Static-body overload: app.get("/health", "ok").
inline fn get(app: Ctx&, path: const u8[:], body: const u8[:]) {
    app.get_text(path, body);
}

inline fn post<F>(app: Ctx&, path: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && app.method == "POST" && app.path == path {
        F();
        app.handled = true;
    }
}

inline fn put<F>(app: Ctx&, path: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && app.method == "PUT" && app.path == path {
        F();
        app.handled = true;
    }
}

inline fn patch<F>(app: Ctx&, path: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && app.method == "PATCH" && app.path == path {
        F();
        app.handled = true;
    }
}

inline fn delete<F>(app: Ctx&, path: const u8[:]) {
    if app.path == path { app.path_matched = true; }
    if !app.handled && app.method == "DELETE" && app.path == path {
        F();
        app.handled = true;
    }
}

// --- single string param: app.get_param("/users/:name") { name => ... } ---

inline fn get_param<F>(app: Ctx&, route: const u8[:]) {
    let prefix = route_prefix(route);
    let seg, ok = match_1param(app.path, prefix);
    if ok { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only) && ok {
        app.params[0] = seg;
        app.n_params = 1;
        F(seg);
        app.handled = true;
    }
}

// The literal prefix of "/users/:name" (everything before "/:").
inline fn route_prefix(route: const u8[:]) -> const u8[:] {
    var i: i64 = 0;
    while i + 1 < route.len {
        if route[i] == '/' && route[i + 1] == ':' {
            return route[..i + 1];
        }
        i++;
    }
    return route;
}

// --- typed i64 param (auto-400 on non-integer) ---

inline fn get_int<F>(app: Ctx&, route: const u8[:]) {
    let prefix = route_prefix(route);
    let seg, ok = match_1param(app.path, prefix);
    if ok { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only) && ok {
        let v, vok = parse_i64_strict(seg);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

inline fn patch_int<F>(app: Ctx&, route: const u8[:]) {
    let prefix = route_prefix(route);
    let seg, ok = match_1param(app.path, prefix);
    if ok { app.path_matched = true; }
    if !app.handled && app.method == "PATCH" && ok {
        let v, vok = parse_i64_strict(seg);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

inline fn delete_int<F>(app: Ctx&, route: const u8[:]) {
    let prefix = route_prefix(route);
    let seg, ok = match_1param(app.path, prefix);
    if ok { app.path_matched = true; }
    if !app.handled && app.method == "DELETE" && ok {
        let v, vok = parse_i64_strict(seg);
        if !vok {
            app.json_error(400, "path parameter must be an integer");
        } else {
            F(v);
        }
        app.handled = true;
    }
}

// --- two params: app.get2("/orgs/:org/repos/:repo") { org, repo => ... } ---

inline fn get2<F>(app: Ctx&, route: const u8[:]) {
    let pre, mid, ok_route = split_2param(route);
    if !ok_route { return; }
    let a, b, ok = match_2param(app.path, pre, mid);
    if ok { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only) && ok {
        app.params[0] = a;
        app.params[1] = b;
        app.n_params = 2;
        F(a, b);
        app.handled = true;
    }
}

// "/orgs/:org/repos/:repo" -> pre "/orgs/", mid "/repos/".
inline fn split_2param(route: const u8[:]) -> const u8[:], const u8[:], bool {
    var first = -1;
    var i: i64 = 0;
    while i + 1 < route.len {
        if route[i] == '/' && route[i + 1] == ':' {
            first = i;
            break;
        }
        i++;
    }
    if first < 0 { return "", "", false; }
    var mid_start = -1;
    var j = first + 2;
    while j < route.len {
        if route[j] == '/' {
            mid_start = j;
            break;
        }
        j++;
    }
    if mid_start <= first + 2 { return "", "", false; }
    var k = mid_start;
    while k + 1 < route.len {
        if route[k] == '/' && route[k + 1] == ':' {
            return route[..first + 1], route[mid_start .. k + 1], true;
        }
        k++;
    }
    return "", "", false;
}

// pre + seg1 + mid + seg2, non-empty segments without '/'.
inline fn match_2param(path: const u8[:], pre: const u8[:], mid: const u8[:]) -> const u8[:], const u8[:], bool {
    if path.len <= pre.len || path[..pre.len] != pre { return "", "", false; }
    var mend = -1;
    var i = pre.len;
    while i + mid.len <= path.len {
        if path[i..i + mid.len] == mid {
            mend = i;
            break;
        }
        i++;
    }
    if mend < 0 { return "", "", false; }
    let a = path[pre.len..mend];
    let b = path[mend + mid.len ..];
    if a.len == 0 || b.len == 0 { return "", "", false; }
    for c in a {
        if c == '/' { return "", "", false; }
    }
    for c in b {
        if c == '/' { return "", "", false; }
    }
    return a, b, true;
}

// --- wildcard tail: app.get_wild("/files/*") { path => ... } ---

inline fn get_wild<F>(app: Ctx&, route: const u8[:]) {
    if route.len == 0 || route[route.len - 1] != '*' { return; }
    let prefix = route[..route.len - 1];
    let rest, ok = app.rest(prefix);
    if ok { app.path_matched = true; }
    if !app.handled && (app.method == "GET" || app.head_only) && ok {
        F(rest);
        app.handled = true;
    }
}

// --- wildcard tail for PATCH: app.patch_wild("/api/todos/") { rest => ... } ---

inline fn patch_wild<F>(app: Ctx&, prefix: const u8[:]) {
    let rest, ok = app.rest(prefix);
    if ok { app.path_matched = true; }
    if !app.handled && app.method == "PATCH" && ok {
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

// --- streaming JSON writer over ctx.res (zero-copy, auto commas/braces) ---

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

inline fn json_run<F>(w: JWriter&) {
    w.out.push('{');
    F(w);
    w.out.push('}');
}

// app.json() { j => j.str("message", "Hello, World!"); } -> 200 + JSON.
inline fn json<F>(app: Ctx&) {
    var w = JWriter { out: app.res, first: true };
    let start = app.res.len;
    json_run(w) { j => F(j); };
    app.json_raw(200, app.res[start..]);
}

// 201 Created variant of json().
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

// Required non-empty string field: runs F(val), else 400 {"error":...}.
inline fn require_str<F>(app: Ctx&, key: const u8[:]) {
    let v, ok = app.body_str(key);
    if !ok || v.len == 0 {
        app.json_error(400, "invalid or missing field");
    } else {
        F(v);
    }
}

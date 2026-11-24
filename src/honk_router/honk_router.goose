// honk_router.goose -- Honk demo dispatch: middleware + routes over honk_ctx.
//
// Dispatch-as-code: an inline if/else graph over (method, path) with
// zero-alloc match helpers. No tables of function pointers, no heap
// closures; handlers take only `ctx` (buffers ride inside it) and stage
// responses; the turn runner (`honk_serve`) emits centrally.

import std;
import json;
import honk_net;
import honk_ctx;
import honk_json;

// Cross-framework bench mode (worker-TLS global, set from argv):
// workload-exact routes on standard paths (/json -> {"message":...},
// /users/:id -> {"id","role"} + X-Frame-Bench, POST /users -> validate + 201)
// with decoration middleware disabled. Default false: behavior bit-identical.
var HONK_BENCH_MODE: bool = false;

// --- demo route matchers (match_1param lives in honk_ctx; views, no copies) ---

// Match "/orgs/:org/repos/:repo" with non-empty segments containing no '/'.
inline fn match_org_repo(path: const u8[:]) -> const u8[:], const u8[:], bool {
    let pre = "/orgs/";
    if path.len <= pre.len || path[..pre.len] != pre { return "", "", false; }
    var org_end = -1;
    var i = pre.len;
    while i < path.len {
        if path[i] == '/' { org_end = i; break; }
        i++;
    }
    if org_end < 0 { return "", "", false; }
    let mid = "/repos/";
    if path.len <= org_end + mid.len { return "", "", false; }
    if path[org_end..org_end + mid.len] != mid { return "", "", false; }
    let repo = path[org_end + mid.len ..];
    if repo.len == 0 { return "", "", false; }
    for c in repo {
        if c == '/' { return "", "", false; }
    }
    let org = path[pre.len..org_end];
    if org.len == 0 { return "", "", false; }
    return org, repo, true;
}

// True when path routes under ANY method (drives 404 vs 405).
inline fn known_path(path: const u8[:]) -> bool {
    if path == "/" || path == "/plaintext" { return true; }
    if path == "/json" || path == "/greet" || path == "/ua" { return true; }
    if path == "/stats" || path == "/large" || path == "/echo" { return true; }
    if path == "/api/typed" || path == "/api/dom" { return true; }
    if path == "/admin/secret" || path == "/__shutdown" { return true; }
    let _, ok1 = match_1param(path, "/users/");
    if ok1 { return true; }
    let _, _, ok2 = match_org_repo(path);
    if ok2 { return true; }
    return false;
}

// --- middleware (inline; zero-alloc; fully inlined into dispatch) ---

// D-007 hot-path exemption: / and /plaintext stage NO extra headers so they
// stay byte-identical to the transport baseline / the bare-C control. The middleware still
// RUNS (two slice compares) so measured overhead is honest.
inline fn hot_exempt(path: const u8[:]) -> bool {
    return path == "/" || path == "/plaintext";
}

// Before-middleware 1: chain-order header. Runs for every request.
inline fn mw_first(c: Ctx&) {
    if hot_exempt(c.path) { return; }
    c.set_header("X-MW-1", "one");
}

// Before-middleware 2: runs after mw_first; plus scoped API header.
inline fn mw_second(c: Ctx&) {
    if hot_exempt(c.path) { return; }
    c.set_header("X-MW-2", "two");
    if c.path.len >= 4 && c.path[..4] == "/api" {
        c.set_header("X-API-Version", "2");
    }
}

// Auth guard: short-circuits /admin/secret with 401 when the Authorization
// header is absent; otherwise decorates ctx (user, authed) for the handler.
// Returns false to skip the downstream handler.
inline fn mw_auth(c: Ctx&) -> bool {
    if c.path == "/admin/secret" {
        let auth, ok = c.header("Authorization");
        if !ok || auth.len == 0 {
            c.status = 401;
            return false;
        }
        c.user = auth;
        c.authed = true;
    }
    return true;
}

// After-middleware: runs after the handler staged its response, before the
// central emit. Stages the serving worker id (formatted into c.tmp, which
// the handler no longer extends, so ranges never overlap staged bodies).
inline fn mw_after(c: Ctx&) {
    if hot_exempt(c.path) { return; }
    let start = c.tmp.len;
    format(c.tmp, honk_worker_id());
    c.set_header("X-Worker", c.tmp[start..]);
}

// Bench-mode W3 middleware: stages exactly one hook header on the dynamic
// user route shape (/users/:id). Runs instead of mw_first/mw_second/mw_after
// when HONK_BENCH_MODE is set, so W1/W2/W4 carry no decoration headers.
inline fn mw_bench(c: Ctx&) {
    let _, ok = match_1param(c.path, "/users/");
    if ok {
        c.set_header("X-Frame-Bench", "1");
    }
}

// --- handlers (ctx-only; stage into ctx; the turn runner emits centrally) ---

inline fn h_plaintext(c: Ctx&) {
    c.text(200, "Hello, World!");
}

inline fn h_json(c: Ctx&) {
    if HONK_BENCH_MODE {
        emit_bench_msg(c.res);   // W2: exactly {"message":"Hello, World!"}
    } else {
        emit_hello_json(c.res);
    }
    c.json_raw(200, c.res[..]);
}

inline fn h_bench_user(c: Ctx&) {
    // W3: {"id":"<id>","role":"<role>"}; X-Frame-Bench staged by mw_bench.
    let id = c.param_str(0);
    let role, rok = c.query("role");
    if rok {
        emit_bench_user(c.res, id, role);
    } else {
        emit_bench_user(c.res, id, "");
    }
    c.json_raw(200, c.res[..]);
}

inline fn h_bench_create(c: Ctx&) {
    // W4: validate {name non-empty str, age int, active bool} -> 201/400.
    var t = BenchUser { name: "", .. };
    var r = json::reader(c.body);
    let ok = parse_bench_user(r, c.tmp, t);
    if !ok || t.name.len == 0 {
        c.text(400, "Bad Request");
        return;
    }
    emit_bench_created(c.res, t);
    c.json_raw(201, c.res[..]);
}

inline fn h_user(c: Ctx&) {
    let id = c.param_str(0);
    let v, vok = c.query("verbose");
    let verbose = vok && v == "1";
    c.res.push('{');
    json::format_key(c.res, "id");
    json::format_string(c.res, id);
    c.res.push(',');
    json::format_key(c.res, "verbose");
    json::format_bool(c.res, verbose);
    c.res.push('}');
    c.json_raw(200, c.res[..]);
}

inline fn h_user_update(c: Ctx&) {
    let id = c.param_str(0);
    c.res.push('{');
    json::format_key(c.res, "id");
    json::format_string(c.res, id);
    c.res.push(',');
    json::format_key(c.res, "updated");
    json::format_bool(c.res, true);
    c.res.push('}');
    c.json_raw(200, c.res[..]);
}

inline fn h_org_repo(c: Ctx&) {
    let org = c.param_str(0);
    let repo = c.param_str(1);
    c.res.push('{');
    json::format_key(c.res, "org");
    json::format_string(c.res, org);
    c.res.push(',');
    json::format_key(c.res, "repo");
    json::format_string(c.res, repo);
    c.res.push('}');
    c.json_raw(200, c.res[..]);
}

inline fn h_greet(c: Ctx&) {
    let name, ok = c.query("name");
    c.res.append("Hello, ");
    if ok && name.len > 0 {
        c.res.append(name);
    } else {
        c.res.append("World");
    }
    c.res.push('!');
    c.text(200, c.res[..]);
}

inline fn h_ua(c: Ctx&) {
    let ua, ok = c.header("User-Agent");
    if ok {
        c.text(200, ua);
    } else {
        c.text(200, "unknown");
    }
}

inline fn h_admin(c: Ctx&) {
    // Reached only via mw_auth (authed == true). X-Handler-Ran proves the
    // handler ran (absent on 401 short-circuit).
    c.set_header("X-Handler-Ran", "1");
    c.res.append("top-secret for ");
    c.res.append(c.user);
    c.text(200, c.res[..]);
}

inline fn h_typed(c: Ctx&) {
    var t = TypedPost { name: "", .. };
    var r = json::reader(c.body);
    let ok = parse_typed_fields(r, c.tmp, t);
    if !ok {
        c.text(400, "Bad Request");
        return;
    }
    emit_typed_post(c.res, t);
    c.json_raw(200, c.res[..]);
}

inline fn h_dom(c: Ctx&) {
    let d = dom_summary(c.body, c.dom, c.dstr);
    if !d.ok {
        c.text(400, "Bad Request");
        return;
    }
    emit_dom_res(c.res, d);
    c.json_raw(200, c.res[..]);
}

inline fn h_echo(c: Ctx&) {
    c.bytes(200, c.body);
}

inline fn h_stats(c: Ctx&) {
    c.res.append("worker=");
    format(c.res, honk_worker_id());
    c.res.append(" active=");
    format(c.res, honk_active_conns());
    c.res.append(" accepted=");
    format(c.res, honk_accepted_total());
    c.res.append(" rejected=");
    format(c.res, honk_rejected_conns());
    c.res.append(" timed_out=");
    format(c.res, honk_timed_out_conns());
    c.res.append(" tx_queued=");
    format(c.res, honk_tx_queued_count());
    c.text(200, c.res[..]);
}

inline fn h_large(c: Ctx&) {
    // Shrink SO_SNDBUF so pipelined 16 KiB responses exercise EAGAIN + EPOLLOUT.
    honk_shrink_sndbuf(c.fd);
    for _ in 1024 {
        c.res.append("0123456789ABCDEF");
    }
    c.text(200, c.res[..]);
}

inline fn h_shutdown(c: Ctx&) {
    honk_request_stop();
    c.keep_alive = false;
    c.text(200, "shutting down");
}

// --- dispatch: middleware chain + method/path graph (staging only) ---
// The turn runner emits centrally afterwards; the runner closes the
// connection when the staged ctx has keep_alive == false.

// GET/HEAD route graph. HEAD shares GET routes; emit() drops the body.
inline fn dispatch_get(c: Ctx&) {
    if c.path == "/" || c.path == "/plaintext" {
        h_plaintext(c);
        return;
    }
    if c.path == "/json" {
        h_json(c);
        return;
    }
    if c.path == "/greet" {
        h_greet(c);
        return;
    }
    if c.path == "/ua" {
        h_ua(c);
        return;
    }
    if c.path == "/stats" {
        h_stats(c);
        return;
    }
    if c.path == "/large" {
        h_large(c);
        return;
    }
    if c.path == "/admin/secret" {
        h_admin(c);
        return;
    }
    let p0, ok1 = match_1param(c.path, "/users/");
    if ok1 {
        c.params[0] = p0;
        c.n_params = 1;
        if HONK_BENCH_MODE {
            h_bench_user(c);   // W3: {"id","role"}
        } else {
            h_user(c);
        }
        return;
    }
    let o, r, ok2 = match_org_repo(c.path);
    if ok2 {
        c.params[0] = o;
        c.params[1] = r;
        c.n_params = 2;
        h_org_repo(c);
        return;
    }
    if known_path(c.path) { c.text(405, "Method Not Allowed"); } else { c.text(404, "Not Found"); }
}

inline fn dispatch(c: Ctx&) {
    // Before-middleware chain (execution order: first, second, auth).
    // Bench mode swaps decoration middleware for the single W3 hook header.
    if HONK_BENCH_MODE {
        mw_bench(c);
    } else {
        mw_first(c);
        mw_second(c);
    }
    if !mw_auth(c) {
        c.text(c.status, status_text(c.status));
        if !HONK_BENCH_MODE {
            mw_after(c);
        }
        return;
    }

    if c.method == "GET" || c.head_only {
        dispatch_get(c);
    } else if c.method == "POST" {
        if c.path == "/users" && HONK_BENCH_MODE {
            h_bench_create(c);   // W4: validate -> 201/400
        } else if c.path == "/echo" {
            h_echo(c);
        } else if c.path == "/api/typed" {
            h_typed(c);
        } else if c.path == "/api/dom" {
            h_dom(c);
        } else if c.path == "/__shutdown" {
            h_shutdown(c);
        } else if known_path(c.path) {
            c.text(405, "Method Not Allowed");
        } else {
            c.text(404, "Not Found");
        }
    } else if c.method == "PUT" {
        let p0, ok1 = match_1param(c.path, "/users/");
        if ok1 {
            c.params[0] = p0;
            c.n_params = 1;
            h_user_update(c);
        } else if known_path(c.path) {
            c.text(405, "Method Not Allowed");
        } else {
            c.text(404, "Not Found");
        }
    } else if c.method == "DELETE" || c.method == "PATCH" || c.method == "OPTIONS" {
        if known_path(c.path) {
            c.text(405, "Method Not Allowed");
        } else {
            c.text(404, "Not Found");
        }
    } else {
        if known_path(c.path) {
            c.text(405, "Method Not Allowed");
        } else {
            c.text(404, "Not Found");
        }
    }

    // After-middleware (the turn runner emits next).
    // (Bench mode stages nothing here: W3's hook header comes from mw_bench.)
    if !HONK_BENCH_MODE {
        mw_after(c);
    }
}

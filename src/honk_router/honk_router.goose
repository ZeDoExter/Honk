// honk_router.goose -- Phase 2 compile-time router, middleware, and handlers.
//
// Dispatch-as-code: an inline if/else graph over (method, path) with
// zero-alloc match helpers. No tables of function pointers, no heap
// closures; the hot path inlines into the worker's pipelining loop.
// Per-request buffers (body_buf, scratch, doc, decoded) live in an explicit
// inner scope per pipelined request so every data-stack top resets on each
// iteration. Transport (honk_conn_read/send/finish) is Phase 1 untouched.

import std;
import json;
import honk_net;
import honk_ctx;
import honk_json;

// Phase 3 cross-framework bench mode (worker-TLS global, set from argv):
// workload-exact routes on standard paths (/json -> {"message":...},
// /users/:id -> {"id","role"} + X-Frame-Bench, POST /users -> validate + 201)
// with Phase 2 decoration middleware disabled. Default false: Phase 1/2
// behavior bit-identical.
var HONK_BENCH_MODE: bool = false;

// --- zero-alloc route matchers (views into path, no copies) ---

// Match `prefix` + single non-empty segment with no '/'. E.g. ("/users/7", "/users/") -> "7".
inline fn match_1param(path: const u8[:], prefix: const u8[:]) -> const u8[:], bool {
    if path.len <= prefix.len { return "", false; }
    if path[..prefix.len] != prefix { return "", false; }
    let rest = path[prefix.len..];
    for c in rest {
        if c == '/' { return "", false; }
    }
    return rest, true;
}

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
// stay byte-identical to Phase 1 / the bare-C control. The middleware still
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
// central emit. Stages the serving worker id (formatted into tmp, a buffer
// the handler no longer extends, so ranges never overlap staged bodies).
inline fn mw_after(c: Ctx&, tmp: u8[>..]&) {
    if hot_exempt(c.path) { return; }
    let start = tmp.len;
    format(tmp, honk_worker_id());
    c.set_header("X-Worker", tmp[start..]);
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

// --- handlers (stage into ctx; dispatch emits centrally) ---

inline fn h_plaintext(c: Ctx&) {
    c.text(200, "Hello, World!");
}

inline fn h_json(c: Ctx&, body_buf: u8[>..]&) {
    if HONK_BENCH_MODE {
        emit_bench_msg(body_buf);   // W2: exactly {"message":"Hello, World!"}
    } else {
        emit_hello_json(body_buf);
    }
    c.json_body(200, body_buf);
}

inline fn h_bench_user(c: Ctx&, body_buf: u8[>..]&) {
    // W3: {"id":"<id>","role":"<role>"}; X-Frame-Bench staged by mw_bench.
    let id = c.param(0);
    let role, rok = c.query("role");
    if rok {
        emit_bench_user(body_buf, id, role);
    } else {
        emit_bench_user(body_buf, id, "");
    }
    c.json_body(200, body_buf);
}

inline fn h_bench_create(c: Ctx&, body_buf: u8[>..]&, scratch: u8[>..]&) {
    // W4: validate {name non-empty str, age int, active bool} -> 201/400.
    var t = BenchUser { name: "", .. };
    var r = json::reader(c.body);
    let ok = parse_bench_user(r, scratch, t);
    if !ok || t.name.len == 0 {
        c.text(400, "Bad Request");
        return;
    }
    emit_bench_created(body_buf, t);
    c.json_body(201, body_buf);
}

inline fn h_user(c: Ctx&, body_buf: u8[>..]&) {
    let id = c.param(0);
    let v, vok = c.query("verbose");
    let verbose = vok && v == "1";
    body_buf.push('{');
    json::format_key(body_buf, "id");
    json::format_string(body_buf, id);
    body_buf.push(',');
    json::format_key(body_buf, "verbose");
    json::format_bool(body_buf, verbose);
    body_buf.push('}');
    c.json_body(200, body_buf);
}

inline fn h_user_update(c: Ctx&, body_buf: u8[>..]&) {
    let id = c.param(0);
    body_buf.push('{');
    json::format_key(body_buf, "id");
    json::format_string(body_buf, id);
    body_buf.push(',');
    json::format_key(body_buf, "updated");
    json::format_bool(body_buf, true);
    body_buf.push('}');
    c.json_body(200, body_buf);
}

inline fn h_org_repo(c: Ctx&, body_buf: u8[>..]&) {
    let org = c.param(0);
    let repo = c.param(1);
    body_buf.push('{');
    json::format_key(body_buf, "org");
    json::format_string(body_buf, org);
    body_buf.push(',');
    json::format_key(body_buf, "repo");
    json::format_string(body_buf, repo);
    body_buf.push('}');
    c.json_body(200, body_buf);
}

inline fn h_greet(c: Ctx&, body_buf: u8[>..]&) {
    let name, ok = c.query("name");
    body_buf.append("Hello, ");
    if ok && name.len > 0 {
        body_buf.append(name);
    } else {
        body_buf.append("World");
    }
    body_buf.push('!');
    c.text(200, body_buf);
}

inline fn h_ua(c: Ctx&) {
    let ua, ok = c.header("User-Agent");
    if ok {
        c.text(200, ua);
    } else {
        c.text(200, "unknown");
    }
}

inline fn h_admin(c: Ctx&, body_buf: u8[>..]&) {
    // Reached only via mw_auth (authed == true). X-Handler-Ran proves the
    // handler ran (absent on 401 short-circuit).
    c.set_header("X-Handler-Ran", "1");
    body_buf.append("top-secret for ");
    body_buf.append(c.user);
    c.text(200, body_buf);
}
inline fn h_typed(c: Ctx&, body_buf: u8[>..]&, scratch: u8[>..]&) {
    var t = TypedPost { name: "", .. };
    var r = json::reader(c.body);
    let ok = parse_typed_fields(r, scratch, t);
    if !ok {
        c.text(400, "Bad Request");
        return;
    }
    emit_typed_post(body_buf, t);
    c.json_body(200, body_buf);
}

inline fn h_dom(c: Ctx&, body_buf: u8[>..]&, doc: json::Node[>..]&, decoded: u8[>..]&) {
    let d = dom_summary(c.body, doc, decoded);
    if !d.ok {
        c.text(400, "Bad Request");
        return;
    }
    emit_dom_res(body_buf, d);
    c.json_body(200, body_buf);
}

inline fn h_echo(c: Ctx&) {
    c.bytes(200, c.body);
}

inline fn h_stats(c: Ctx&, body_buf: u8[>..]&) {
    body_buf.append("worker=");
    format(body_buf, honk_worker_id());
    body_buf.append(" active=");
    format(body_buf, honk_active_conns());
    body_buf.append(" accepted=");
    format(body_buf, honk_accepted_total());
    body_buf.append(" rejected=");
    format(body_buf, honk_rejected_conns());
    body_buf.append(" timed_out=");
    format(body_buf, honk_timed_out_conns());
    body_buf.append(" tx_queued=");
    format(body_buf, honk_tx_queued_count());
    c.text(200, body_buf);
}

inline fn h_large(c: Ctx&, body_buf: u8[>..]&, fd: i32) {
    // Shrink SO_SNDBUF so pipelined 16 KiB responses exercise EAGAIN + EPOLLOUT.
    honk_shrink_sndbuf(fd);
    for _ in 1024 {
        body_buf.append("0123456789ABCDEF");
    }
    c.text(200, body_buf);
}

inline fn h_shutdown(c: Ctx&) {
    honk_request_stop();
    c.keep_alive = false;
    c.text(200, "shutting down");
}

// --- dispatch: middleware chain + method/path graph + central emit ---
// Returns true when the connection must close after this response.

// GET/HEAD route graph. HEAD shares GET routes; emit() drops the body.
inline fn dispatch_get(c: Ctx&, body_buf: u8[>..]&, fd: i32) {
    if c.path == "/" || c.path == "/plaintext" {
        h_plaintext(c);
        return;
    }
    if c.path == "/json" {
        h_json(c, body_buf);
        return;
    }
    if c.path == "/greet" {
        h_greet(c, body_buf);
        return;
    }
    if c.path == "/ua" {
        h_ua(c);
        return;
    }
    if c.path == "/stats" {
        h_stats(c, body_buf);
        return;
    }
    if c.path == "/large" {
        h_large(c, body_buf, fd);
        return;
    }
    if c.path == "/admin/secret" {
        h_admin(c, body_buf);
        return;
    }
    let p0, ok1 = match_1param(c.path, "/users/");
    if ok1 {
        c.params[0] = p0;
        c.n_params = 1;
        if HONK_BENCH_MODE {
            h_bench_user(c, body_buf);   // W3: {"id","role"}
        } else {
            h_user(c, body_buf);
        }
        return;
    }
    let o, r, ok2 = match_org_repo(c.path);
    if ok2 {
        c.params[0] = o;
        c.params[1] = r;
        c.n_params = 2;
        h_org_repo(c, body_buf);
        return;
    }
    if known_path(c.path) { c.text(405, "Method Not Allowed"); } else { c.text(404, "Not Found"); }
}

inline fn dispatch(c: Ctx&, out: u8[>..]&, date: const u8[:],
                   body_buf: u8[>..]&, scratch: u8[>..]&,
                   doc: json::Node[>..]&, decoded: u8[>..]&,
                   fd: i32) -> bool {
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
            mw_after(c, body_buf);
        }
        c.emit(out, date);
        return false;
    }

    if c.method == "GET" || c.head_only {
        dispatch_get(c, body_buf, fd);
    } else if c.method == "POST" {
        if c.path == "/users" && HONK_BENCH_MODE {
            h_bench_create(c, body_buf, scratch);   // W4: validate -> 201/400
        } else if c.path == "/echo" {
            h_echo(c);
        } else if c.path == "/api/typed" {
            h_typed(c, body_buf, scratch);
        } else if c.path == "/api/dom" {
            h_dom(c, body_buf, doc, decoded);
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
            h_user_update(c, body_buf);
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

    // After-middleware, then the single central emit.
    // (Bench mode stages nothing here: W3's hook header comes from mw_bench.)
    if !HONK_BENCH_MODE {
        mw_after(c, body_buf);
    }
    c.emit(out, date);
    return !c.keep_alive;
}

// Phase 2 turn: identical transport to Phase 1, but each pipelined request
// runs in an explicit inner scope with its own body_buf/scratch/doc/decoded
// so per-request data-stack tops reset every iteration. Returns the rx_buf
// stack top (== entry baseline) for discipline assertions.
inline fn process_ready_fd2(fd: i32, date_hdr: const u8[:]) -> i64 {
    var rx_buf: u8[>..] = [];
    let base_top = honk_debug_stack_base(rx_buf);
    let total = honk_conn_read(fd, rx_buf);
    if total <= 0 {
        assert(honk_debug_stack_top(rx_buf) == base_top);
        return honk_debug_stack_top(rx_buf);
    }

    var tx_buf: u8[>..] = [];
    var cursor: i32 = 0;
    var close_conn = false;

    while cursor < rx_buf.len {
        var req = RawReq { .. };
        let rem_slice: const u8[:] = rx_buf[cursor..];
        let pret = honk_parse_req(rem_slice, req);
        if pret == -2 {
            break;
        }
        if pret < 0 {
            write_error_response(tx_buf, pret, date_hdr);
            close_conn = true;
            break;
        }
        {
            // Per-request scope: all four builders reset at block exit.
            var body_buf: u8[>..] = [];
            var scratch: u8[>..] = [];
            var doc: json::Node[>..] = [];
            var decoded: u8[>..] = [];
            let method = rem_slice[req.method_off .. req.method_end];
            let full_path = rem_slice[req.path_off .. req.path_end];
            let body = rem_slice[req.body_off .. req.body_end];
            // Raw header block: bytes between the request line and body_off.
            let hb = req.body_off as! i64;
            var line_end = -1;
            var k: i64 = 0;
            while k + 1 < hb {
                if rem_slice[k] == '\r' && rem_slice[k + 1] == '\n' {
                    line_end = k;
                    break;
                }
                k++;
            }
            let hdrs = if line_end >= 0 { rem_slice[line_end + 2 .. hb] } else { rem_slice[hb..hb] };
            let ka = req.keep_alive != 0;
            var ctx = make_ctx(method, full_path, body, hdrs, ka);
            let must_close = dispatch(ctx, tx_buf, date_hdr, body_buf, scratch, doc, decoded, fd);
            cursor += req.consumed;
            if must_close {
                close_conn = true;
                break;
            }
        }
    }

    if tx_buf.len > 0 {
        honk_send(fd, tx_buf);
    }
    honk_conn_finish(fd, rx_buf, cursor, if close_conn { 1 } else { 0 });
    assert(honk_debug_stack_top(rx_buf) == base_top);
    return honk_debug_stack_top(rx_buf);
}

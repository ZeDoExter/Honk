// examples/quickstart/app.goose -- minimal realistic Honk application.
//
// Shows: static routes, :params, ?query, before/after middleware, an auth
// guard, and a typed JSON POST (json::Reader). Single worker, stdlib only.
//
// Build:  goose build examples/quickstart/app.goose -o examples/quickstart/app
// Run:    ./examples/quickstart/app [port]
// Then:   curl http://127.0.0.1:18080/ ...
// Shutdown: curl -X POST http://127.0.0.1:18080/__shutdown

import std;
import os;
import json;
import honk_net from "../../src/honk_net";
import honk_ctx from "../../src/honk_ctx";

// --- middleware ---

// Adds an example header to every response except / (keeps / tiny).
inline fn mw_example(c: Ctx&) {
    if c.path == "/" { return; }
    c.set_header("X-Example", "quickstart");
}

// Guard: /private needs `Authorization: Bearer <token>`; decorates ctx.user.
inline fn mw_guard(c: Ctx&) -> bool {
    if c.path == "/private" {
        let auth, ok = c.header("Authorization");
        if !ok || auth.len < 8 || auth[..7] != "Bearer " {
            c.status = 401;
            return false;
        }
        c.user = auth[7..];
        c.authed = true;
    }
    return true;
}

// --- typed POST body: {username: string, email: string, age?: int} ---

struct Signup {
    username: const u8[:],
    has_username: bool,
    email: const u8[:],
    has_email: bool,
    age: i64,
    has_age: bool,
}

fn parse_signup(r: json::Reader&, scratch: u8[>..]&, s: Signup&) -> bool {
    json::each_member(r) { key =>
        if key == "username" {
            s.username = json::read_string(r, scratch);
            s.has_username = true;
        } else if key == "email" {
            s.email = json::read_string(r, scratch);
            s.has_email = true;
        } else if key == "age" {
            s.age = json::read_int(r);
            s.has_age = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) { return false; }
    if !s.has_username || !s.has_email { return false; }
    return true;
}

// --- handlers (stage into ctx; dispatch emits centrally) ---

inline fn h_root(c: Ctx&) {
    c.text(200, "Welcome to Honk! Try /hello/ada?title=Dr, /private, /signup");
}

inline fn h_hello(c: Ctx&, body_buf: u8[>..]&) {
    let name = c.param(0);
    let title, ok = c.query("title");
    body_buf.append("Hello, ");
    if ok && title.len > 0 {
        body_buf.append(title);
        body_buf.push(' ');
    }
    body_buf.append(name);
    body_buf.push('!');
    c.text(200, body_buf);
}

inline fn h_private(c: Ctx&, body_buf: u8[>..]&) {
    body_buf.append("hello ");
    body_buf.append(c.user);
    body_buf.append(", this route is guarded by middleware");
    c.text(200, body_buf);
}

inline fn h_signup(c: Ctx&, body_buf: u8[>..]&, scratch: u8[>..]&) {
    var s = Signup { username: "", .. };
    var r = json::reader(c.body);
    if !parse_signup(r, scratch, s) || s.username.len == 0 || s.email.len == 0 {
        c.text(400, "Bad Request");
        return;
    }
    body_buf.push('{');
    json::format_key(body_buf, "created");
    json::format_bool(body_buf, true);
    body_buf.push(',');
    json::format_key(body_buf, "username");
    json::format_string(body_buf, s.username);
    if s.has_age {
        body_buf.push(',');
        json::format_key(body_buf, "age");
        json::format_int(body_buf, s.age);
    }
    body_buf.push('}');
    c.json_body(201, body_buf);
}

// --- dispatch ---

inline fn dispatch(c: Ctx&, out: u8[>..]&, date: const u8[:],
                   body_buf: u8[>..]&, scratch: u8[>..]&) -> bool {
    mw_example(c);
    if !mw_guard(c) {
        c.text(c.status, status_text(c.status));
        c.emit(out, date);
        return false;
    }
    if c.method == "GET" || c.head_only {
        if c.path == "/" {
            h_root(c);
        } else if c.path == "/private" {
            h_private(c, body_buf);
        } else {
            // Single-segment /hello/:name (no '/' inside).
            let pre = "/hello/";
            if c.path.len > pre.len && c.path[..pre.len] == pre {
                let rest = c.path[pre.len..];
                var slash = false;
                for ch in rest {
                    if ch == '/' { slash = true; break; }
                }
                if !slash {
                    c.params[0] = rest;
                    c.n_params = 1;
                    h_hello(c, body_buf);
                } else {
                    c.text(404, "Not Found");
                }
            } else {
                c.text(404, "Not Found");
            }
        }
    } else if c.method == "POST" {
        if c.path == "/signup" {
            h_signup(c, body_buf, scratch);
        } else if c.path == "/__shutdown" {
            honk_request_stop();
            c.keep_alive = false;
            c.text(200, "shutting down");
        } else {
            c.text(404, "Not Found");
        }
    } else {
        c.text(404, "Not Found");
    }
    c.emit(out, date);
    return !c.keep_alive;
}

// --- turn loop: same transport pattern as src/honk_router.goose ---

inline fn process_fd(fd: i32, date_hdr: const u8[:]) {
    var rx_buf: u8[>..] = [];
    let total = honk_conn_read(fd, rx_buf);
    if total <= 0 { return; }
    var tx_buf: u8[>..] = [];
    var cursor: i32 = 0;
    var close_conn = false;
    while cursor < rx_buf.len {
        var req = RawReq { .. };
        let rem: const u8[:] = rx_buf[cursor..];
        let pret = honk_parse_req(rem, req);
        if pret == -2 { break; }
        if pret < 0 {
            write_error_response(tx_buf, pret, date_hdr);
            close_conn = true;
            break;
        }
        {
            var body_buf: u8[>..] = [];
            var scratch: u8[>..] = [];
            let method = rem[req.method_off .. req.method_end];
            let full_path = rem[req.path_off .. req.path_end];
            let body = rem[req.body_off .. req.body_end];
            let hb = req.body_off as! i64;
            var line_end = -1;
            var k: i64 = 0;
            while k + 1 < hb {
                if rem[k] == '\r' && rem[k + 1] == '\n' { line_end = k; break; }
                k++;
            }
            let hdrs = if line_end >= 0 { rem[line_end + 2 .. hb] } else { rem[hb..hb] };
            var ctx = make_ctx(method, full_path, body, hdrs, req.keep_alive != 0);
            if dispatch(ctx, tx_buf, date_hdr, body_buf, scratch) {
                close_conn = true;
                break;
            }
            cursor += req.consumed;
        }
    }
    if tx_buf.len > 0 { honk_send(fd, tx_buf); }
    honk_conn_finish(fd, rx_buf, cursor, if close_conn { 1 } else { 0 });
}

thread_fn worker(port: i32) {
    honk_set_timeouts(30000, 10000);
    guard honk_worker_init(port) == 0 else { abort("honk_worker_init failed"); }
    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];
    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 100);
        if nfds <= 0 { continue; }
        assert(nfds <= 256);
        for i in nfds { process_fd(ready_fds[i], date_hdr); }
        if honk_should_stop() != 0 { honk_worker_shutdown(); break; }
    }
}

fn main() {
    var port: i32 = 18080;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    print("quickstart listening on port ", port);
    flush_stdout();
    let tid = thread_spawn(worker, port);
    thread_wait(tid);
}

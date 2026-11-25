// honk_test.goose -- zero-socket in-memory unit test harness (`honk::` namespace).
//
// Opt-in submodule (`import honk.src.honk_test.honk_test;`): compiles zero
// code into production binaries and runs routes directly in memory without
// opening a TCP port. Pure value-array storage in `Tester` avoids borrow-root
// lifetime constraints across repeated test calls.
//
//   var t = honk::tester();
//   t.get("/users/ada") { app => my_routes(app); };
//   assert(t.status == 200 && t.body() == "ada");

namespace honk;

import std;
import json;
import src.honk_ctx.honk_ctx;
import src.honk_app.honk_app;

struct Tester {
    status: i64,
    ctype_buf: u8[64],
    ctype_len: i64,
    buf: u8[16384],
    body_len: i64,
    hdr_buf: u8[4096],
    hdr_len: i64,
}

fn tester() -> Tester {
    return Tester {
        status: 0,
        ctype_buf: [0; 64],
        ctype_len: 0,
        buf: [0; 16384],
        body_len: 0,
        hdr_buf: [0; 4096],
        hdr_len: 0,
    };
}

inline fn body(t: Tester&) -> const u8[:] {
    let n = if t.body_len >= 0 && t.body_len <= 16384 { t.body_len } else { 0 };
    return t.buf[..n];
}

inline fn ctype(t: Tester&) -> const u8[:] {
    let n = if t.ctype_len >= 0 && t.ctype_len <= 64 { t.ctype_len } else { 0 };
    return t.ctype_buf[..n];
}

// Case-insensitive lookup of an emitted response header from the last request.
fn header(t: Tester&, name: const u8[:]) -> const u8[:], bool {
    let n = if t.hdr_len >= 0 && t.hdr_len <= 4096 { t.hdr_len } else { 0 };
    let hdrs = t.hdr_buf[..n];
    var pos: i64 = 0;
    while pos < hdrs.len {
        var eol = hdrs.len;
        var i = pos;
        while i < hdrs.len {
            if hdrs[i] == '\r' { eol = i; break; }
            i++;
        }
        var colon = -1;
        var j = pos;
        while j < eol {
            if hdrs[j] == ':' { colon = j; break; }
            j++;
        }
        if colon > pos {
            let hn = hdrs[pos..colon];
            if hn.len == name.len {
                var same = true;
                for k in hn.len {
                    if !eq_ci(hn[k], name[k]) { same = false; break; }
                }
                if same {
                    var vs = colon + 1;
                    while vs < eol && (hdrs[vs] == ' ' || hdrs[vs] == '\t') { vs++; }
                    var ve = eol;
                    while ve > vs && (hdrs[ve - 1] == ' ' || hdrs[ve - 1] == '\t') { ve--; }
                    return hdrs[vs..ve], true;
                }
            }
        }
        pos = eol + 2;
    }
    return "", false;
}

// Execute one synthetic HTTP/1.1 request against `F(app)` in memory.
// Copies inputs into a turn-local `rx_buf` (matching real `honk::request`) so
// caller-constructed headers/bodies never borrow-couple with `ctx` (§9.2).
inline fn req<F>(t: Tester&, method: const u8[:], target: const u8[:],
                 req_hdrs: const u8[:], req_body: const u8[:]) {
    var rx_buf: u8[>..] = [];
    let m_end = method.len;
    rx_buf.append(method);
    let t_end = m_end + target.len;
    rx_buf.append(target);
    let h_end = t_end + req_hdrs.len;
    rx_buf.append(req_hdrs);
    rx_buf.append(req_body);

    var res_buf: u8[>..] = [];
    var tmp_buf: u8[>..] = [];
    var dom_buf: json::Node[>..] = [];
    var dstr_buf: u8[>..] = [];
    var tx_buf: u8[>..] = [];

    var ctx = make_ctx(rx_buf[..m_end], rx_buf[m_end..t_end], rx_buf[h_end..],
                       rx_buf[t_end..h_end], true, -1,
                       "Thu, 01 Jan 1970 00:00:00 GMT",
                       res_buf, tmp_buf, dom_buf, dstr_buf);
    app_run(ctx) { c => F(c); };
    ctx.emit(tx_buf, ctx.date);

    t.status = ctx.status;

    let cl = if ctx.ctype.len <= 64 { ctx.ctype.len } else { 64 };
    for i in cl { t.ctype_buf[i] = ctx.ctype[i]; }
    t.ctype_len = cl;

    let no_body = ctx.head_only || ctx.status == 204;
    let src_body = if no_body { ctx.resp_body[..0] } else { ctx.resp_body };
    let bl = if src_body.len <= 16384 { src_body.len } else { 16384 };
    for i in bl { t.buf[i] = src_body[i]; }
    t.body_len = bl;

    // Extract emitted header block (between status line and \r\n\r\n).
    var line1 = -1;
    var hdr_end = tx_buf.len;
    var k: i64 = 0;
    while k + 1 < tx_buf.len {
        if tx_buf[k] == '\r' && tx_buf[k + 1] == '\n' {
            if line1 < 0 { line1 = k + 2; }
            if k + 3 < tx_buf.len && tx_buf[k + 2] == '\r' && tx_buf[k + 3] == '\n' {
                hdr_end = k + 2;
                break;
            }
        }
        k++;
    }
    let hs = if line1 >= 0 && line1 <= hdr_end { tx_buf[line1..hdr_end] } else { tx_buf[..0] };
    let hl = if hs.len <= 4096 { hs.len } else { 4096 };
    for i in hl { t.hdr_buf[i] = hs[i]; }
    t.hdr_len = hl;
}

inline fn get<F>(t: Tester&, target: const u8[:]) {
    t.req("GET", target, "", "") { app => F(app); };
}

inline fn get_headers<F>(t: Tester&, target: const u8[:], hdrs: const u8[:]) {
    t.req("GET", target, hdrs, "") { app => F(app); };
}

inline fn delete<F>(t: Tester&, target: const u8[:]) {
    t.req("DELETE", target, "", "") { app => F(app); };
}

inline fn post_json<F>(t: Tester&, target: const u8[:], json_body: const u8[:]) {
    t.req("POST", target, "Content-Type: application/json\r\n", json_body) { app => F(app); };
}

inline fn put_json<F>(t: Tester&, target: const u8[:], json_body: const u8[:]) {
    t.req("PUT", target, "Content-Type: application/json\r\n", json_body) { app => F(app); };
}

inline fn patch_json<F>(t: Tester&, target: const u8[:], json_body: const u8[:]) {
    t.req("PATCH", target, "Content-Type: application/json\r\n", json_body) { app => F(app); };
}

// honk_ctx.goose -- Honk zero-copy Context / Request / Response API.
//
// A Ctx holds request views (method, path, query, body, raw headers) as
// zero-copy `const u8[:]` slices into the turn's `rx_buf`, plus staged
// response state (status, content-type, body slice, extra headers), plus
// references to the per-request builders (`res` response builder, `tmp`
// decode/scratch space, `dom`/`dstr` JSON workspace) so handlers take a
// single `ctx` with no buffer plumbing. `responded` lets the turn
// runner default unstaged requests to 404.
// Handlers STAGE via text()/bytes()/json_raw()/...; the single central
// emit() produces status + Content-Length + Date + Connection framing.
// No heap allocations: all views root at rx_buf, the per-request builders,
// or static literals.

namespace honk;

import std;
import json;
import src.honk_net.honk_net;

struct RespHdr { name: const u8[:], val: const u8[:] }

struct Ctx {
    // Zero-copy request views into rx_buf.
    method: const u8[:],
    path: const u8[:],    // query string stripped
    query_str: const u8[:],   // raw query without '?'
    body: const u8[:],
    hdrs: const u8[:],    // raw header block (request line excluded)
    keep_alive: bool,
    head_only: bool,      // method == HEAD: emit headers + Content-Length, no body
    fd: i32,               // serving socket (rarely needed; e.g. sndbuf tuning)
    // Per-request builders (refs; owned by the turn scope, reset per request).
    res: u8[>..]&,
    tmp: u8[>..]&,
    dom: json::Node[>..]&,
    dstr: u8[>..]&,
    // Route params (e.g. /users/:id -> params[0] / param("id"); /* -> tail).
    params: const u8[:][8],
    param_names: const u8[:][8],
    n_params: i64,
    tail: const u8[:],
    // Middleware decoration (set by auth guard).
    user: const u8[:],
    authed: bool,
    // Staged response state.
    status: i64,
    ctype: const u8[:],
    resp_body: const u8[:],   // direct slice OR per-request builder range
    extras: RespHdr[16],
    n_extra: i64,
    responded: bool,      // set by every staging helper; turn defaults false -> 404
    // Route DSL state (first-match-wins + 404/405 tracking + lifecycle).
    handled: bool,        // a route or guard claimed this request
    path_matched: bool,   // some route shape matched (drives 405 vs 404)
    json_err_mode: bool,  // emit JSON {"error":...} for default 404/405/401
    t0_ns: i64,           // > 0 when server_timing() is active for this request
    // Memoized request-body DOM for body_* helpers (parsed once per request).
    dom_ready: bool,
    dom_ok: bool,
    dom_root: json::Node?,
    // Static file staging (honk_static): headers slice + open fd + bytes.
    resp_hdrs: const u8[:],
    resp_file_fd: i32,     // -1 when no file is staged
    resp_file_off: i64,    // first byte of the staged [off, off + n) slice
    resp_file_n: i64,
    resp_len: i64,         // >= 0 overrides Content-Length (HEAD/empty); -1 = body.len
    sent: bool,            // static response queued for direct send (skip emit)
    date: const u8[:],     // cached Date header value for this turn
}

// Build a Ctx from parsed request slices. full_path still carries '?query'.
fn make_ctx(method: const u8[:], full_path: const u8[:], body: const u8[:],
            hdrs: const u8[:], keep_alive: bool, fd: i32, date: const u8[:],
            res: u8[>..]&, tmp: u8[>..]&, dom: json::Node[>..]&, dstr: u8[>..]&) -> Ctx {
    var qi = full_path.len;
    for c, i in full_path {
        if c == '?' { qi = i; break; }
    }
    let path = full_path[..qi];
    let q = if qi < full_path.len { full_path[qi + 1 ..] } else { full_path[qi..] };
    return Ctx {
        method: method,
        path: path,
        query_str: q,
        body: body,
        hdrs: hdrs,
        keep_alive: keep_alive,
        head_only: method == "HEAD",
        fd: fd,
        res: res,
        tmp: tmp,
        dom: dom,
        dstr: dstr,
        tail: "",
        user: "",
        authed: false,
        status: 200,
        ctype: "text/plain",
        resp_body: "",
        responded: false,
        handled: false,
        path_matched: false,
        json_err_mode: false,
        t0_ns: 0,
        dom_ready: false,
        dom_ok: false,
        dom_root: null,
        resp_hdrs: "",
        resp_file_fd: -1,
        resp_file_off: 0,
        resp_file_n: 0,
        resp_len: -1,
        sent: false,
        date: date,
        ..
    };
}

inline fn eq_ci(a: u8, b: u8) -> bool {
    if a == b { return true; }
    return ascii::is_alpha(a) && (a | 32) == (b | 32);
}

// Case-insensitive request header lookup. Zero-copy: returns a trimmed view
// into the raw header block. O(headers) scan per call.
fn header(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    var pos: i64 = 0;
    while pos < c.hdrs.len {
        var eol = c.hdrs.len;
        var i = pos;
        while i < c.hdrs.len {
            if c.hdrs[i] == '\r' { eol = i; break; }
            i++;
        }
        var colon = -1;
        var j = pos;
        while j < eol {
            if c.hdrs[j] == ':' { colon = j; break; }
            j++;
        }
        if colon > pos {
            let hn = c.hdrs[pos..colon];
            if hn.len == name.len {
                var same = true;
                for k in hn.len {
                    if !eq_ci(hn[k], name[k]) { same = false; break; }
                }
                if same {
                    var vs = colon + 1;
                    while vs < eol && (c.hdrs[vs] == ' ' || c.hdrs[vs] == '\t') { vs++; }
                    var ve = eol;
                    while ve > vs && (c.hdrs[ve - 1] == ' ' || c.hdrs[ve - 1] == '\t') { ve--; }
                    return c.hdrs[vs..ve], true;
                }
            }
        }
        pos = eol + 2;
    }
    return "", false;
}

// Raw key=val&key2=val2 lookup (shared by query strings and URL-encoded forms).
fn kv_lookup(raw: const u8[:], key: const u8[:]) -> const u8[:], bool {
    if raw.len == 0 { return "", false; }
    var pos: i64 = 0;
    while pos <= raw.len {
        var end = raw.len;
        var i = pos;
        while i < raw.len {
            if raw[i] == '&' { end = i; break; }
            i++;
        }
        var eq = end;
        var j = pos;
        while j < end {
            if raw[j] == '=' { eq = j; break; }
            j++;
        }
        if eq > pos && raw[pos..eq] == key {
            let vs = if eq < end { eq + 1 } else { end };
            return raw[vs..end], true;
        }
        if end == raw.len { break; }
        pos = end + 1;
    }
    return "", false;
}

// Raw query parameter lookup (?a=1&b=2). Zero-copy view; no percent-decoding.
fn query(c: Ctx&, key: const u8[:]) -> const u8[:], bool {
    return kv_lookup(c.query_str, key);
}

// Route parameter by index; "" when out of range.
inline fn param_str(c: Ctx&, i: i64) -> const u8[:] {
    if i >= 0 && i < 8 && i < c.n_params { return c.params[i]; }
    return "";
}

// Overloaded `app.param(0)` and `app.param("id")` lookups (zero-copy views).
inline fn param(c: Ctx&, i: i64) -> const u8[:] {
    return c.param_str(i);
}

inline fn param(c: Ctx&, name: const u8[:]) -> const u8[:] {
    let n = if c.n_params <= 8 { c.n_params } else { 8 };
    for i in n {
        if c.param_names[i] == name { return c.params[i]; }
    }
    return "";
}

// Strict i64 parse: optional sign, 1+ ASCII digits, i64 range. No spaces.
fn parse_i64_strict(s: const u8[:]) -> i64, bool {
    if s.len == 0 { return 0, false; }
    var i: i64 = 0;
    var neg = false;
    if s[0] == '-' {
        neg = true;
        i = 1;
    } else if s[0] == '+' {
        i = 1;
    }
    if i >= s.len { return 0, false; }
    var acc: u64 = 0;
    let lim: u64 = if neg { 9223372036854775808 } else { 9223372036854775807 };
    while i < s.len {
        let d = s[i];
        if d < '0' || d > '9' { return 0, false; }
        let dig: u64 = d - '0';
        if acc > (lim - dig) / 10 { return 0, false; }
        acc = acc * 10 + dig;
        i++;
    }
    if neg {
        if acc == 9223372036854775808 { return (0 - 9223372036854775807) - 1, true; }
        return 0 - (acc as! i64), true;
    }
    return acc as! i64, true;
}

// Route parameter parsed as i64; false when missing, non-numeric, or overflowing.
inline fn param_int(c: Ctx&, i: i64) -> i64, bool {
    if i < 0 || i >= 8 || i >= c.n_params { return 0, false; }
    return parse_i64_strict(c.params[i]);
}

// Query value or default when the key is absent.
inline fn query_str_or(c: Ctx&, key: const u8[:], default_val: const u8[:]) -> const u8[:] {
    let v, ok = c.query(key);
    if ok { return v; }
    return default_val;
}

// Query value parsed as i64, or default when absent/invalid/overflowing.
inline fn query_int_or(c: Ctx&, key: const u8[:], default_val: i64) -> i64 {
    let v, ok = c.query(key);
    if !ok { return default_val; }
    let n, nok = parse_i64_strict(v);
    if !nok { return default_val; }
    return n;
}

inline fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return (c - 'a') as! i64 + 10; }
    if c >= 'A' && c <= 'F' { return (c - 'A') as! i64 + 10; }
    return -1;
}

// Percent-decode s. Fast path: zero-copy slice when no % (or +) is present.
// Slow path: decodes %XX (and + iff plus_is_space) into c.tmp. False on
// malformed hex (callers must ignore the slice unless ok).
fn url_decode(c: Ctx&, s: const u8[:], plus_is_space: bool) -> const u8[:], bool {
    var need = false;
    for ch in s {
        if ch == '%' || (plus_is_space && ch == '+') { need = true; break; }
    }
    if !need { return s, true; }
    let start = c.tmp.len;
    var i: i64 = 0;
    while i < s.len {
        let ch = s[i];
        if ch == '%' {
            if i + 2 >= s.len { return "", false; }
            let hi = hex_val(s[i + 1]);
            let lo = hex_val(s[i + 2]);
            if hi < 0 || lo < 0 { return "", false; }
            c.tmp.push((hi * 16 + lo) as! u8);
            i += 3;
        } else if plus_is_space && ch == '+' {
            c.tmp.push(' ');
            i++;
        } else {
            c.tmp.push(ch);
            i++;
        }
    }
    return c.tmp[start..], true;
}

// Decoded query value (+ means space); false when absent or malformed.
inline fn query_decoded(c: Ctx&, key: const u8[:]) -> const u8[:], bool {
    let v, ok = c.query(key);
    if !ok { return "", false; }
    return url_decode(c, v, true);
}

// Decoded route parameter (+ stays literal); false when absent or malformed.
inline fn param_decoded(c: Ctx&, i: i64) -> const u8[:], bool {
    if i < 0 || i >= 8 || i >= c.n_params { return "", false; }
    return url_decode(c, c.params[i], false);
}

// Decoded named route parameter (e.g. app.param_dec("name")).
inline fn param_dec(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    let n = if c.n_params <= 8 { c.n_params } else { 8 };
    for i in n {
        if c.param_names[i] == name {
            return url_decode(c, c.params[i], false);
        }
    }
    return "", false;
}

// Bearer token from `Authorization: Bearer <token>` (scheme case-insensitive).
inline fn bearer_token(c: Ctx&) -> const u8[:], bool {
    let auth, ok = c.header("Authorization");
    if !ok { return "", false; }
    var sp = -1;
    for ch, i in auth {
        if ch == ' ' || ch == '\t' { sp = i; break; }
    }
    if sp <= 0 { return "", false; }
    let scheme = auth[..sp];
    if scheme.len != 6 { return "", false; }
    let want = "bearer";
    for k in 6 {
        if !eq_ci(scheme[k], want[k]) { return "", false; }
    }
    var vs = sp + 1;
    while vs < auth.len && (auth[vs] == ' ' || auth[vs] == '\t') { vs++; }
    if vs >= auth.len { return "", false; }
    return auth[vs..], true;
}

// Zero-copy cookie lookup from the Cookie header (`a=1; b=2`).
fn cookie(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    let hdr, ok = c.header("Cookie");
    if !ok { return "", false; }
    var pos: i64 = 0;
    while pos < hdr.len {
        while pos < hdr.len && (hdr[pos] == ' ' || hdr[pos] == ';') { pos++; }
        var end = hdr.len;
        var i = pos;
        while i < hdr.len {
            if hdr[i] == ';' { end = i; break; }
            i++;
        }
        if end > pos {
            var eq = end;
            var j = pos;
            while j < end {
                if hdr[j] == '=' { eq = j; break; }
                j++;
            }
            var ne = eq;
            while ne > pos && hdr[ne - 1] == ' ' { ne--; }
            if ne > pos && hdr[pos..ne] == name {
                let vs = if eq < end { eq + 1 } else { end };
                var s = vs;
                while s < end && hdr[s] == ' ' { s++; }
                var ve = end;
                while ve > s && hdr[ve - 1] == ' ' { ve--; }
                return hdr[s..ve], true;
            }
        }
        pos = end + 1;
    }
    return "", false;
}

// Stage a Set-Cookie header (value built as `name=val[; opts]` in c.tmp).
inline fn set_cookie(c: Ctx&, name: const u8[:], val: const u8[:], opts: const u8[:] = "") {
    let start = c.tmp.len;
    c.tmp.append(name);
    c.tmp.push('=');
    c.tmp.append(val);
    if opts.len > 0 {
        c.tmp.append("; ");
        c.tmp.append(opts);
    }
    c.set_header("Set-Cookie", c.tmp[start..]);
}

// Expire a cookie immediately (`Max-Age=0; HttpOnly`).
inline fn delete_cookie(c: Ctx&, name: const u8[:], path: const u8[:] = "/") {
    let start = c.tmp.len;
    c.tmp.append(name);
    c.tmp.append("=; Path=");
    c.tmp.append(path);
    c.tmp.append("; Max-Age=0; HttpOnly");
    c.set_header("Set-Cookie", c.tmp[start..]);
}

// Peer socket IPv4 address (`"127.0.0.1"` in unit tests).
inline fn client_ip(c: Ctx&) -> const u8[:] {
    let start = c.tmp.len;
    honk_conn_ip(c.fd, c.tmp);
    return c.tmp[start..];
}

// Client IP aware of reverse-proxy headers (`X-Forwarded-For`, `X-Real-IP`).
fn real_ip(c: Ctx&) -> const u8[:] {
    let xff, ok1 = c.header("X-Forwarded-For");
    if ok1 && xff.len > 0 {
        var end = xff.len;
        for ch, i in xff {
            if ch == ',' { end = i; break; }
        }
        var s: i64 = 0;
        while s < end && (xff[s] == ' ' || xff[s] == '\t') { s++; }
        while end > s && (xff[end - 1] == ' ' || xff[end - 1] == '\t') { end--; }
        if end > s { return xff[s..end]; }
    }
    let xri, ok2 = c.header("X-Real-IP");
    if ok2 && xri.len > 0 { return xri; }
    return c.client_ip();
}
// Trusted reverse-proxy networks, parsed once in `main` via `parse_cidrs`
// and passed per request to `real_ip_trusted` (max 8 networks).
struct Cidrs {
    nets: u32[8],
    masks: u32[8],
    n: i64,
}

// Strict dotted-quad parse (`a.b.c.d`, 0-255 per octet). No DNS, no IPv6.
fn parse_ipv4(s: const u8[:]) -> u32, bool {
    var parts: i64[4] = [0; 4];
    var n: i64 = 0;
    var pos: i64 = 0;
    while pos <= s.len {
        var end = s.len;
        var i = pos;
        while i < s.len {
            if s[i] == '.' { end = i; break; }
            i++;
        }
        if n >= 4 || end == pos || end - pos > 3 { return 0, false; }
        var v: i64 = 0;
        var j = pos;
        while j < end {
            if s[j] < '0' || s[j] > '9' { return 0, false; }
            v = v * 10 + (s[j] - '0');
            j++;
        }
        if v > 255 { return 0, false; }
        parts[n] = v;
        n++;
        if end == s.len { break; }
        pos = end + 1;
    }
    if n != 4 { return 0, false; }
    return ((parts[0] as! u32) << 24) | ((parts[1] as! u32) << 16)
         | ((parts[2] as! u32) << 8) | (parts[3] as! u32), true;
}

// Parse `"127.0.0.1,10.0.0.0/8"` into masked networks (max 8, extras
// dropped; bare IPs mean /32; malformed entries skipped). False when
// nothing usable parsed.
fn parse_cidrs(s: const u8[:]) -> Cidrs, bool {
    var c = Cidrs { nets: [0; 8], masks: [0; 8], n: 0 };
    var pos: i64 = 0;
    while pos <= s.len {
        var end = s.len;
        var i = pos;
        while i < s.len {
            if s[i] == ',' { end = i; break; }
            i++;
        }
        var es = pos;
        while es < end && (s[es] == ' ' || s[es] == '\t') { es++; }
        var ee = end;
        while ee > es && (s[ee - 1] == ' ' || s[ee - 1] == '\t') { ee--; }
        if ee > es {
            var slash = -1;
            var k = es;
            while k < ee {
                if s[k] == '/' { slash = k; break; }
                k++;
            }
            let ip_end = if slash < 0 { ee } else { slash };
            let ip, ok = parse_ipv4(s[es..ip_end]);
            if ok {
                var bits: i64 = 32;
                var bok = true;
                if slash >= 0 {
                    if slash + 1 >= ee { bok = false; }
                    else {
                        var b: i64 = 0;
                        var m = slash + 1;
                        while m < ee {
                            if s[m] < '0' || s[m] > '9' { bok = false; break; }
                            b = b * 10 + (s[m] - '0');
                            m++;
                        }
                        if b < 0 || b > 32 { bok = false; }
                        else { bits = b; }
                    }
                }
                if bok && c.n < 8 {
                    let sh: u32 = (32 - bits) as! u32;
                    let mask: u32 = if bits == 0 { 0 } else { (0xffffffff as! u32) << sh };
                    c.nets[c.n] = ip & mask;
                    c.masks[c.n] = mask;
                    c.n++;
                }
            }
        }
        if end == s.len { break; }
        pos = end + 1;
    }
    return c, c.n > 0;
}

inline fn ip_in_nets(ip: u32, nets: Cidrs) -> bool {
    let n = if nets.n <= 8 { nets.n } else { 8 };
    for i in n {
        if (ip & nets.masks[i]) == nets.nets[i] { return true; }
    }
    return false;
}

// Spoof-resistant client IP: proxy headers are honored ONLY when the socket
// peer itself is trusted (`client_ip` in `nets`). `X-Forwarded-For` is then
// walked RIGHT to LEFT, skipping trusted hops, returning the first
// non-trusted hop (an external client can only spoof entries LEFT of what
// the trusted proxy appended). Falls back to a syntactically valid
// `X-Real-IP`, else the socket peer (fail-closed on malformed hops).
fn real_ip_trusted(c: Ctx&, nets: Cidrs) -> const u8[:] {
    let peer = c.client_ip();
    let peer_ip, peer_ok = parse_ipv4(peer);
    if !peer_ok || !ip_in_nets(peer_ip, nets) { return peer; }
    let xff, ok1 = c.header("X-Forwarded-For");
    if ok1 && xff.len > 0 {
        var hops: const u8[:][16] = [xff[..0]; 16];
        var nh: i64 = 0;
        var pos: i64 = 0;
        while pos <= xff.len && nh < 16 {
            var end = xff.len;
            var i = pos;
            while i < xff.len {
                if xff[i] == ',' { end = i; break; }
                i++;
            }
            var hs = pos;
            while hs < end && (xff[hs] == ' ' || xff[hs] == '\t') { hs++; }
            var he = end;
            while he > hs && (xff[he - 1] == ' ' || xff[he - 1] == '\t') { he--; }
            if he > hs {
                hops[nh] = xff[hs..he];
                nh++;
            }
            if end == xff.len { break; }
            pos = end + 1;
        }
        var k = nh - 1;
        while k >= 0 {
            let hip, hok = parse_ipv4(hops[k]);
            if !hok { return peer; }
            if !ip_in_nets(hip, nets) { return hops[k]; }
            k--;
        }
    }
    let xri, ok2 = c.header("X-Real-IP");
    if ok2 && xri.len > 0 {
        var rs = 0;
        while rs < xri.len && (xri[rs] == ' ' || xri[rs] == '\t') { rs++; }
        var re = xri.len;
        while re > rs && (xri[re - 1] == ' ' || xri[re - 1] == '\t') { re--; }
        if re > rs {
            let _, rok = parse_ipv4(xri[rs..re]);
            if rok { return xri[rs..re]; }
        }
    }
    return peer;
}

// Stage a custom response header (max 16; extras beyond are dropped).
fn set_header(c: Ctx&, name: const u8[:], val: const u8[:]) {
    if c.n_extra < 16 {
        c.extras[c.n_extra] = RespHdr { name: name, val: val };
        c.n_extra++;
    }
}

// Stage a plain-text response.
inline fn text(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "text/plain";
    c.resp_body = s;
    c.responded = true;
}

// Stage an HTML response.
inline fn html(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "text/html";
    c.resp_body = s;
    c.responded = true;
}

// Stage a binary response.
inline fn bytes(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "application/octet-stream";
    c.resp_body = s;
    c.responded = true;
}

// Stage a JSON response (body already serialized into a per-request buffer).
inline fn json_raw(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "application/json";
    c.resp_body = s;
    c.responded = true;
}

// Stage a JSON error object {"error":"<msg>"} (msg escaped into c.res).
inline fn json_error(c: Ctx&, code: i64, msg: const u8[:]) {
    let start = c.res.len;
    c.res.push('{');
    json::format_key(c.res, "error");
    json::format_string(c.res, msg);
    c.res.push('}');
    c.json_raw(code, c.res[start..]);
}

// Stage an empty 204 response.
inline fn no_content(c: Ctx&) {
    c.status = 204;
    c.ctype = "text/plain";
    c.resp_body = "";
    c.responded = true;
}

// Stage a redirect (Location header + empty body; default 302).
inline fn redirect(c: Ctx&, location: const u8[:], code: i64 = 302) {
    c.status = code;
    c.ctype = "text/plain";
    c.resp_body = "";
    c.set_header("Location", location);
    c.responded = true;
}

// Wildcard match: `prefix` + rest (rest may contain '/'; must be non-empty).
inline fn rest(c: Ctx&, prefix: const u8[:]) -> const u8[:], bool {
    if c.path.len <= prefix.len { return "", false; }
    if c.path[..prefix.len] != prefix { return "", false; }
    return c.path[prefix.len..], true;
}

// Match `prefix` + single non-empty segment with no '/'. E.g. ("/users/7", "/users/") -> "7".
inline fn match_1param(path: const u8[:], prefix: const u8[:]) -> const u8[:], bool {
    if path.len <= prefix.len { return "", false; }
    if path[..prefix.len] != prefix { return "", false; }
    let seg = path[prefix.len..];
    for c in seg {
        if c == '/' { return "", false; }
    }
    return seg, true;
}

// True when s holds a ".." path segment (traversal attempt).
inline fn has_dotdot(s: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < s.len {
        if (i == 0 || s[i - 1] == '/') && i + 1 < s.len && s[i] == '.' && s[i + 1] == '.'
            && (i + 2 >= s.len || s[i + 2] == '/') {
            return true;
        }
        i++;
    }
    return false;
}

// CORS: allow-anywhere headers (for React/Vite/Next.js frontends).
inline fn cors_allow_all(c: Ctx&) {
    c.set_header("Access-Control-Allow-Origin", "*");
    c.set_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
    c.set_header("Access-Control-Allow-Headers", "Content-Type, Authorization");
}

// CORS with a fixed origin instead of *.
inline fn cors_with_origin(c: Ctx&, origin: const u8[:]) {
    c.set_header("Access-Control-Allow-Origin", origin);
    c.set_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
    c.set_header("Access-Control-Allow-Headers", "Content-Type, Authorization");
}

// CORS preflight answer: allow-all headers + empty 204.
inline fn cors_preflight(c: Ctx&) {
    cors_allow_all(c);
    c.status = 204;
    c.ctype = "text/plain";
    c.resp_body = "";
    c.responded = true;
}
// Exact-match `Origin` against a comma-separated allowlist (OWS around
// commas trimmed). Full-string equality only, never prefix/substring.
// Returns the matched allowlist entry (byte-identical to `origin`).
fn cors_match_origin(origin: const u8[:], allow: const u8[:]) -> const u8[:], bool {
    if origin.len == 0 || allow.len == 0 { return "", false; }
    var pos: i64 = 0;
    while pos <= allow.len {
        var end = allow.len;
        var i = pos;
        while i < allow.len {
            if allow[i] == ',' { end = i; break; }
            i++;
        }
        var s = pos;
        while s < end && (allow[s] == ' ' || allow[s] == '\t') { s++; }
        var e = end;
        while e > s && (allow[e - 1] == ' ' || allow[e - 1] == '\t') { e--; }
        if e > s && allow[s..e] == origin { return allow[s..e], true; }
        if end == allow.len { break; }
        pos = end + 1;
    }
    return "", false;
}

fn status_text(code: i64) -> const u8[:] {
    if code == 101 { return "Switching Protocols"; }
    if code == 200 { return "OK"; }
    if code == 201 { return "Created"; }
    if code == 204 { return "No Content"; }
    if code == 206 { return "Partial Content"; }
    if code == 301 { return "Moved Permanently"; }
    if code == 302 { return "Found"; }
    if code == 303 { return "See Other"; }
    if code == 304 { return "Not Modified"; }
    if code == 307 { return "Temporary Redirect"; }
    if code == 308 { return "Permanent Redirect"; }
    if code == 400 { return "Bad Request"; }
    if code == 401 { return "Unauthorized"; }
    if code == 403 { return "Forbidden"; }
    if code == 404 { return "Not Found"; }
    if code == 405 { return "Method Not Allowed"; }
    if code == 408 { return "Request Timeout"; }
    if code == 409 { return "Conflict"; }
    if code == 412 { return "Precondition Failed"; }
    if code == 413 { return "Payload Too Large"; }
    if code == 414 { return "URI Too Long"; }
    if code == 415 { return "Unsupported Media Type"; }
    if code == 416 { return "Range Not Satisfiable"; }
    if code == 422 { return "Unprocessable Entity"; }
    if code == 426 { return "Upgrade Required"; }
    if code == 429 { return "Too Many Requests"; }
    if code == 431 { return "Request Header Fields Too Large"; }
    if code == 500 { return "Internal Server Error"; }
    if code == 501 { return "Not Implemented"; }
    if code == 502 { return "Bad Gateway"; }
    if code == 503 { return "Service Unavailable"; }
    if code == 504 { return "Gateway Timeout"; }
    return "Internal Server Error";
}

// Central response emit: the ONLY place HTTP framing is produced.
// Field order matches the transport baseline (Content-Type, Date, [extras...],
// [Connection: close], Content-Length) so /plaintext stays byte-identical
// to the bare-C control when no extras are staged.
fn emit(c: Ctx&, out: u8[>..]&, date: const u8[:]) {
    out.append("HTTP/1.1 ");
    format(out, c.status);
    out.push(' ');
    out.append(status_text(c.status));
    out.append("\r\nContent-Type: ");
    out.append(c.ctype);
    out.append("\r\nDate: ");
    out.append(date);
    assert(c.n_extra <= 16);
    let n_ex = c.n_extra;
    assert(n_ex <= 16);
    for i in n_ex {
        out.append("\r\n");
        out.append(c.extras[i].name);
        out.append(": ");
        out.append(c.extras[i].val);
    }
    if !c.keep_alive {
        out.append("\r\nConnection: close");
    }
    let no_body = c.head_only || c.status == 204 || c.status == 304;
    let blen = if c.status == 204 || c.status == 304 { 0 } else if c.resp_len >= 0 { c.resp_len } else { c.resp_body.len };
    out.append("\r\nContent-Length: ");
    format(out, blen);
    out.append("\r\n\r\n");
    if !no_body {
        out.append(c.resp_body);
    }
}

// --- URL-encoded form & RFC 7578 zero-copy multipart/form-data ---

struct Part {
    name: const u8[:],
    filename: const u8[:],
    ctype: const u8[:],
    data: const u8[:],
    has_file: bool,
}

inline fn eq_prefix_ci(s: const u8[:], want: const u8[:]) -> bool {
    if s.len < want.len { return false; }
    for i in want.len {
        if !eq_ci(s[i], want[i]) { return false; }
    }
    return true;
}

// Extract boundary token from `Content-Type: multipart/form-data; boundary=...`.
fn multipart_boundary(c: Ctx&) -> const u8[:], bool {
    let ct, ok = c.header("Content-Type");
    if !ok || !eq_prefix_ci(ct, "multipart/form-data") { return "", false; }
    if ct.len > 19 && ct[19] != ';' && ct[19] != ' ' && ct[19] != '\t' {
        return "", false;
    }
    var pos: i64 = 19;
    while pos < ct.len {
        while pos < ct.len && (ct[pos] == ';' || ct[pos] == ' ' || ct[pos] == '\t') { pos++; }
        if eq_prefix_ci(ct[pos..], "boundary=") {
            pos += 9;
            if pos < ct.len && ct[pos] == '"' {
                pos++;
                var qend = pos;
                while qend < ct.len && ct[qend] != '"' { qend++; }
                if qend >= ct.len { return "", false; }
                let bnd = ct[pos..qend];
                return bnd, bnd.len >= 1 && bnd.len <= 70;
            }
            var end = pos;
            while end < ct.len && ct[end] != ';' && ct[end] != ' ' && ct[end] != '\t' { end++; }
            let bnd = ct[pos..end];
            return bnd, bnd.len >= 1 && bnd.len <= 70;
        }
        while pos < ct.len && ct[pos] != ';' { pos++; }
    }
    return "", false;
}

inline fn match_boundary_at(b: const u8[:], pos: i64, bnd: const u8[:]) -> bool {
    if pos + 2 + bnd.len > b.len { return false; }
    return b[pos] == '-' && b[pos + 1] == '-' && b[pos + 2 .. pos + 2 + bnd.len] == bnd;
}

fn parse_part_headers(phdrs: const u8[:], empty_ref: const u8[:]) -> Part, bool {
    let no_ct: const u8[:] = if false { empty_ref } else { "" };
    let bad = Part { name: empty_ref, filename: empty_ref, ctype: no_ct, data: empty_ref, has_file: false };
    var pname = empty_ref;
    var pfile = empty_ref;
    var pctype = empty_ref;
    var has_file = false;
    var has_disp = false;

    var pos: i64 = 0;
    while pos < phdrs.len {
        var eol = phdrs.len;
        var i = pos;
        while i < phdrs.len {
            if phdrs[i] == '\r' { eol = i; break; }
            i++;
        }
        var colon = -1;
        var j = pos;
        while j < eol {
            if phdrs[j] == ':' { colon = j; break; }
            j++;
        }
        if colon > pos {
            let hn = phdrs[pos..colon];
            var vs = colon + 1;
            while vs < eol && (phdrs[vs] == ' ' || phdrs[vs] == '\t') { vs++; }
            var ve = eol;
            while ve > vs && (phdrs[ve - 1] == ' ' || phdrs[ve - 1] == '\t') { ve--; }
            let hv = phdrs[vs..ve];

            if hn.len == 12 && eq_prefix_ci(hn, "content-type") {
                if hv.len > 0 { pctype = hv; }
            } else if hn.len == 19 && eq_prefix_ci(hn, "content-disposition") {
                if !eq_prefix_ci(hv, "form-data") { return bad, false; }
                has_disp = true;
                var p: i64 = 9;
                while p < hv.len {
                    while p < hv.len && (hv[p] == ';' || hv[p] == ' ' || hv[p] == '\t') { p++; }
                    var is_name = false;
                    var is_fname = false;
                    if eq_prefix_ci(hv[p..], "name=") {
                        is_name = true;
                        p += 5;
                    } else if eq_prefix_ci(hv[p..], "filename=") {
                        is_fname = true;
                        p += 9;
                    }
                    if is_name || is_fname {
                        var val = empty_ref;
                        if p < hv.len && hv[p] == '"' {
                            p++;
                            let qs = p;
                            while p < hv.len && hv[p] != '"' { p++; }
                            if p >= hv.len { return bad, false; }
                            val = hv[qs..p];
                            p++;
                        } else {
                            let us = p;
                            while p < hv.len && hv[p] != ';' && hv[p] != ' ' && hv[p] != '\t' { p++; }
                            val = hv[us..p];
                        }
                        if is_name {
                            pname = val;
                        } else {
                            has_file = true;
                            // RFC 7578 §4.2: strip any client directory prefix (`/` or `\`).
                            var base_idx: i64 = 0;
                            for ch, idx in val {
                                if ch == '/' || ch == '\\' { base_idx = idx + 1; }
                            }
                            pfile = val[base_idx..];
                        }
                    } else {
                        while p < hv.len && hv[p] != ';' { p++; }
                    }
                }
            }
        }
        pos = eol + 2;
    }
    if !has_disp || pname.len == 0 {
        return bad, false;
    }
    let final_ct: const u8[:] = if pctype.len > 0 { pctype } else { "text/plain" };
    return Part { name: pname, filename: pfile, ctype: final_ct, data: empty_ref, has_file: has_file }, true;
}

// Stream every part in a `multipart/form-data` body as zero-copy slices into `c.body`.
// Returns `false` when `Content-Type` is not multipart or the framing is malformed.
inline fn each_part<F>(c: Ctx&) -> bool {
    let bnd, bok = c.multipart_boundary();
    if !bok { return false; }
    let b = c.body;
    let empty_ref = b[..0];
    var bpos: i64 = -1;
    if match_boundary_at(b, 0, bnd) {
        bpos = 0;
    } else {
        var s: i64 = 0;
        while s + 4 + bnd.len <= b.len {
            if b[s] == '\r' && b[s + 1] == '\n' && match_boundary_at(b, s + 2, bnd) {
                bpos = s + 2;
                break;
            }
            s++;
        }
    }
    if bpos < 0 { return false; }

    var after_b = bpos + 2 + bnd.len;
    if after_b + 2 <= b.len && b[after_b] == '-' && b[after_b + 1] == '-' {
        return true;
    }
    while after_b < b.len && (b[after_b] == ' ' || b[after_b] == '\t') { after_b++; }
    if after_b + 2 > b.len || b[after_b] != '\r' || b[after_b + 1] != '\n' {
        return false;
    }
    var part_start = after_b + 2;

    while part_start <= b.len {
        var phdrs = empty_ref;
        var data_start = -1;
        if part_start + 2 <= b.len && b[part_start] == '\r' && b[part_start + 1] == '\n' {
            return false;
        }
        var h = part_start;
        while h + 3 < b.len {
            if b[h] == '\r' && b[h + 1] == '\n' && b[h + 2] == '\r' && b[h + 3] == '\n' {
                phdrs = b[part_start .. h + 2];
                data_start = h + 4;
                break;
            }
            h++;
        }
        if data_start < 0 { return false; }

        var delim_pos = -1;
        var next_part = -1;
        var is_final = false;
        var scan = data_start;
        while scan + 4 + bnd.len <= b.len {
            if b[scan] == '\r' && b[scan + 1] == '\n' && match_boundary_at(b, scan + 2, bnd) {
                var tail = scan + 4 + bnd.len;
                if tail + 2 <= b.len && b[tail] == '-' && b[tail + 1] == '-' {
                    delim_pos = scan;
                    is_final = true;
                    break;
                }
                while tail < b.len && (b[tail] == ' ' || b[tail] == '\t') { tail++; }
                if tail + 2 <= b.len && b[tail] == '\r' && b[tail + 1] == '\n' {
                    delim_pos = scan;
                    next_part = tail + 2;
                    break;
                }
            }
            scan++;
        }
        if delim_pos < 0 { return false; }

        let meta, mok = parse_part_headers(phdrs, empty_ref);
        if !mok { return false; }
        let part = Part {
            name: meta.name,
            filename: meta.filename,
            ctype: meta.ctype,
            data: b[data_start..delim_pos],
            has_file: meta.has_file,
        };
        F(part);

        if is_final { return true; }
        part_start = next_part;
    }
    return false;
}

// Look up a part (field or file) by `field_name` in a `multipart/form-data` request.
fn multipart_part(c: Ctx&, field_name: const u8[:]) -> Part, bool {
    let empty_ref = c.body[..0];
    let no_ct: const u8[:] = if false { empty_ref } else { "" };
    var out = Part { name: empty_ref, filename: empty_ref, ctype: no_ct, data: empty_ref, has_file: false };
    var found = false;
    let valid = c.each_part() { p =>
        if !found && p.name == field_name {
            out = p;
            found = true;
        }
    };
    if !valid || !found {
        return Part { name: empty_ref, filename: empty_ref, ctype: no_ct, data: empty_ref, has_file: false }, false;
    }
    return out, true;
}

// Look up an uploaded file part (`filename` non-empty) by `field_name`.
fn multipart_file(c: Ctx&, field_name: const u8[:]) -> Part, bool {
    let empty_ref = c.body[..0];
    let no_ct: const u8[:] = if false { empty_ref } else { "" };
    var out = Part { name: empty_ref, filename: empty_ref, ctype: no_ct, data: empty_ref, has_file: false };
    var found = false;
    let valid = c.each_part() { p =>
        if !found && p.name == field_name && p.has_file && p.filename.len > 0 {
            out = p;
            found = true;
        }
    };
    if !valid || !found {
        return Part { name: empty_ref, filename: empty_ref, ctype: no_ct, data: empty_ref, has_file: false }, false;
    }
    return out, true;
}

// Form field lookup: decodes `application/x-www-form-urlencoded` (`+` -> space, `%XX`)
// and transparently reads non-file text fields from `multipart/form-data` requests.
fn form(c: Ctx&, key: const u8[:]) -> const u8[:], bool {
    let ct, ct_ok = c.header("Content-Type");
    if ct_ok && eq_prefix_ci(ct, "multipart/form-data") {
        let p, pok = c.multipart_part(key);
        if pok && !p.has_file { return p.data, true; }
        return "", false;
    }
    let raw_v, ok = kv_lookup(c.body, key);
    if ok {
        return url_decode(c, raw_v, true);
    }
    // Slow path for percent/plus-encoded field names (e.g. `first+name=Ada`).
    var pos: i64 = 0;
    while pos < c.body.len {
        var end = c.body.len;
        var i = pos;
        while i < c.body.len {
            if c.body[i] == '&' { end = i; break; }
            i++;
        }
        var eq = end;
        var has_enc = false;
        var j = pos;
        while j < end {
            if c.body[j] == '=' { eq = j; break; }
            if c.body[j] == '%' || c.body[j] == '+' { has_enc = true; }
            j++;
        }
        if has_enc && eq > pos {
            let dk, dok = url_decode(c, c.body[pos..eq], true);
            if dok && dk == key {
                let vs = if eq < end { eq + 1 } else { end };
                return url_decode(c, c.body[vs..end], true);
            }
        }
        if end == c.body.len { break; }
        pos = end + 1;
    }
    return "", false;
}

inline fn form_or(c: Ctx&, key: const u8[:], default_val: const u8[:]) -> const u8[:] {
    let v, ok = c.form(key);
    if ok { return v; }
    return default_val;
}

inline fn form_int(c: Ctx&, key: const u8[:]) -> i64, bool {
    let v, ok = c.form(key);
    if !ok { return 0, false; }
    return parse_i64_strict(v);
}

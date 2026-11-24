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

import std;
import json;

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
    // Route params (e.g. /users/:id -> params[0]; /orgs/:org/repos/:repo -> [0],[1]).
    params: const u8[:][4],
    n_params: i64,
    // Middleware decoration (set by auth guard).
    user: const u8[:],
    authed: bool,
    // Staged response state.
    status: i64,
    ctype: const u8[:],
    resp_body: const u8[:],   // direct slice OR per-request builder range
    extras: RespHdr[8],
    n_extra: i64,
    responded: bool,      // set by every staging helper; turn defaults false -> 404
}

// Build a Ctx from parsed request slices. full_path still carries '?query'.
fn make_ctx(method: const u8[:], full_path: const u8[:], body: const u8[:],
            hdrs: const u8[:], keep_alive: bool, fd: i32,
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
        user: "",
        authed: false,
        status: 200,
        ctype: "text/plain",
        resp_body: "",
        responded: false,
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

// Raw query parameter lookup (?a=1&b=2). Zero-copy view; no percent-decoding.
fn query(c: Ctx&, key: const u8[:]) -> const u8[:], bool {
    if c.query_str.len == 0 { return "", false; }
    var pos: i64 = 0;
    while pos <= c.query_str.len {
        var end = c.query_str.len;
        var i = pos;
        while i < c.query_str.len {
            if c.query_str[i] == '&' { end = i; break; }
            i++;
        }
        var eq = end;
        var j = pos;
        while j < end {
            if c.query_str[j] == '=' { eq = j; break; }
            j++;
        }
        if eq > pos && c.query_str[pos..eq] == key {
            let vs = if eq < end { eq + 1 } else { end };
            return c.query_str[vs..end], true;
        }
        if end == c.query_str.len { break; }
        pos = end + 1;
    }
    return "", false;
}

// Route parameter by index; "" when out of range.
inline fn param_str(c: Ctx&, i: i64) -> const u8[:] {
    if i >= 0 && i < 4 && i < c.n_params { return c.params[i]; }
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
    if i < 0 || i >= 4 || i >= c.n_params { return 0, false; }
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
    if i < 0 || i >= 4 || i >= c.n_params { return "", false; }
    return url_decode(c, c.params[i], false);
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

// Stage a custom response header (max 8; extras beyond are dropped).
fn set_header(c: Ctx&, name: const u8[:], val: const u8[:]) {
    if c.n_extra < 8 {
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

fn status_text(code: i64) -> const u8[:] {
    if code == 200 { return "OK"; }
    if code == 201 { return "Created"; }
    if code == 204 { return "No Content"; }
    if code == 301 { return "Moved Permanently"; }
    if code == 302 { return "Found"; }
    if code == 303 { return "See Other"; }
    if code == 307 { return "Temporary Redirect"; }
    if code == 308 { return "Permanent Redirect"; }
    if code == 400 { return "Bad Request"; }
    if code == 401 { return "Unauthorized"; }
    if code == 403 { return "Forbidden"; }
    if code == 404 { return "Not Found"; }
    if code == 405 { return "Method Not Allowed"; }
    if code == 422 { return "Unprocessable Entity"; }
    return "Internal Server Error";
}

// Central response emit: the ONLY place HTTP framing is produced.
// Field order matches Phase 1 (Content-Type, Date, [extras...],
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
    assert(c.n_extra <= 8);
    let n_ex = c.n_extra;
    assert(n_ex <= 8);
    for i in n_ex {
        out.append("\r\n");
        out.append(c.extras[i].name);
        out.append(": ");
        out.append(c.extras[i].val);
    }
    if !c.keep_alive {
        out.append("\r\nConnection: close");
    }
    let no_body = c.head_only || c.status == 204;
    let blen = if c.status == 204 { 0 } else { c.resp_body.len };
    out.append("\r\nContent-Length: ");
    format(out, blen);
    out.append("\r\n\r\n");
    if !no_body {
        out.append(c.resp_body);
    }
}

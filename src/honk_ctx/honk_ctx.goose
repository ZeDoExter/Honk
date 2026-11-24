// honk_ctx.goose -- Phase 2 zero-copy Context / Request / Response API.
//
// A Ctx holds request views (method, path, query, body, raw headers) as
// zero-copy `const u8[:]` slices into the turn's `rx_buf`, plus staged
// response state (status, content-type, body slice, extra headers).
// Handlers STAGE via text()/bytes()/json_body(); the single central emit()
// in dispatch produces status + Content-Length + Date + Connection framing,
// so HEAD (headers, no body) and Content-Length correctness hold by
// construction. No heap allocations: all views root at rx_buf, the
// per-request body_buf/scratch, or static literals.

import std;

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
    // Route params (e.g. /users/:id -> params[0]; /orgs/:org/repos/:repo -> [0],[1]).
    params: const u8[:][4],
    n_params: i64,
    // Middleware decoration (set by auth guard).
    user: const u8[:],
    authed: bool,
    // Staged response state.
    status: i64,
    ctype: const u8[:],
    resp_body: const u8[:],   // direct slice OR per-request body_buf range
    extras: RespHdr[8],
    n_extra: i64,
}

// Build a Ctx from parsed request slices. full_path still carries '?query'.
fn make_ctx(method: const u8[:], full_path: const u8[:], body: const u8[:],
            hdrs: const u8[:], keep_alive: bool) -> Ctx {
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
        user: "",
        authed: false,
        status: 200,
        ctype: "text/plain",
        resp_body: "",
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
fn param(c: Ctx&, i: i64) -> const u8[:] {
    if i >= 0 && i < 4 && i < c.n_params { return c.params[i]; }
    return "";
}

// Stage a custom response header (max 8; extras beyond are dropped).
fn set_header(c: Ctx&, name: const u8[:], val: const u8[:]) {
    if c.n_extra < 8 {
        c.extras[c.n_extra] = RespHdr { name: name, val: val };
        c.n_extra++;
    }
}

// Stage a plain-text response.
fn text(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "text/plain";
    c.resp_body = s;
}

// Stage a binary response.
fn bytes(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "application/octet-stream";
    c.resp_body = s;
}

// Stage a JSON response (body already serialized into a per-request buffer).
fn json_body(c: Ctx&, status: i64, s: const u8[:]) {
    c.status = status;
    c.ctype = "application/json";
    c.resp_body = s;
}

fn status_text(code: i64) -> const u8[:] {
    if code == 200 { return "OK"; }
    if code == 201 { return "Created"; }
    if code == 204 { return "No Content"; }
    if code == 400 { return "Bad Request"; }
    if code == 401 { return "Unauthorized"; }
    if code == 403 { return "Forbidden"; }
    if code == 404 { return "Not Found"; }
    if code == 405 { return "Method Not Allowed"; }
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

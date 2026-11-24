// honk_static.goose -- zero-copy static file serving over kernel sendfile().
//
// try_serve_file validates + opens root/rel, stages response headers, and
// hands the open fd to the turn, which send()s headers first and then pushes
// file bytes via honk_sendfile_data (EAGAIN tails resume on EPOLLOUT).
// File bytes never pass through Goose buffers. At most one file per turn;
// pipelined tails resume next EPOLLIN via the normal partial_rx stash.
//
// Security: NUL/backslash/malformed-% rejected; decoded segments checked
// (.. rejected, . and empties skipped); open uses O_NOFOLLOW + fstat S_ISREG
// (symlinks/dirs/FIFOs/devices never served). Non-GET/HEAD stages 405.

import std;
import honk_ctx;

extern fn honk_file_open(root: const u8[:], rel: const u8[:]) -> i32;
extern fn honk_file_size(file_fd: i32) -> i64;
extern fn honk_file_close(file_fd: i32);

inline fn ext_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for k in a.len {
        if !eq_ci(a[k], b[k]) { return false; }
    }
    return true;
}

fn mime_for_rel(rel: const u8[:]) -> const u8[:] {
    var dot = -1;
    var i = rel.len - 1;
    while i >= 0 {
        if rel[i] == '.' {
            dot = i;
            break;
        }
        if rel[i] == '/' { break; }
        i--;
    }
    if dot < 0 { return "application/octet-stream"; }
    let ext = rel[dot + 1 ..];
    if ext_eq(ext, "html") { return "text/html"; }
    if ext_eq(ext, "css") { return "text/css"; }
    if ext_eq(ext, "js") { return "text/javascript"; }
    if ext_eq(ext, "mjs") { return "text/javascript"; }
    if ext_eq(ext, "json") { return "application/json"; }
    if ext_eq(ext, "svg") { return "image/svg+xml"; }
    if ext_eq(ext, "png") { return "image/png"; }
    if ext_eq(ext, "jpg") { return "image/jpeg"; }
    if ext_eq(ext, "jpeg") { return "image/jpeg"; }
    if ext_eq(ext, "webp") { return "image/webp"; }
    if ext_eq(ext, "ico") { return "image/x-icon"; }
    if ext_eq(ext, "wasm") { return "application/wasm"; }
    if ext_eq(ext, "txt") { return "text/plain"; }
    if ext_eq(ext, "woff2") { return "font/woff2"; }
    return "application/octet-stream";
}

// Serve c.path from root. Returns true when handled:
//   - GET/HEAD miss, traversal, malformed, non-regular: false (unstaged;
//     caller falls back to 404, SPA index.html, ...).
//   - Other methods: stages 405, returns true.
//   - Directory/empty remainder: tries index.html when with_index.
// Root should be a static literal (borrowed, never copied).
fn try_serve_file(c: Ctx&, root: const u8[:], with_index: bool) -> bool {
    if c.method != "GET" && !c.head_only {
        c.text(405, "Method Not Allowed");
        return true;
    }
    if root.len == 0 || c.path.len == 0 || c.path[0] != '/' {
        return false;
    }
    return serve_rel(c, root, c.path[1..], with_index);
}

// Serve an explicit relative path (no leading slash). Same validation and
// staging as try_serve_file; used for SPA index.html fallback and tests.
fn serve_rel(c: Ctx&, root: const u8[:], raw: const u8[:], with_index: bool) -> bool {
    if root.len == 0 { return false; }
    for ch in raw {
        if ch == 0 || ch == '\\' { return false; }
    }
    // Decode %XX (+ stays literal in paths) and normalize segments.
    let dec, ok = url_decode(c, raw, false);
    if !ok { return false; }
    for ch in dec {
        if ch == 0 { return false; }
    }
    let start = c.tmp.len;
    var pos: i64 = 0;
    var segs: i64 = 0;
    let trailing_slash = dec.len > 0 && dec[dec.len - 1] == '/';
    while pos < dec.len {
        var end = dec.len;
        var i = pos;
        while i < dec.len {
            if dec[i] == '/' {
                end = i;
                break;
            }
            i++;
        }
        if end > pos {
            let seg = dec[pos..end];
            if seg.len == 2 && seg[0] == '.' && seg[1] == '.' {
                return false;   // traversal attempt
            }
            if !(seg.len == 1 && seg[0] == '.') {
                if segs > 0 { c.tmp.push('/'); }
                c.tmp.append(seg);
                segs++;
            }
        }
        if end == dec.len { break; }
        pos = end + 1;
    }
    var rel = c.tmp[start..];
    if segs == 0 || trailing_slash {
        if !with_index { return false; }
        if segs > 0 { c.tmp.push('/'); }
        c.tmp.append("index.html");
        rel = c.tmp[start..];
    }
    let fd = honk_file_open(root, rel);
    if fd < 0 { return false; }
    let size = honk_file_size(fd);
    if size < 0 {
        honk_file_close(fd);
        return false;
    }
    let mime = mime_for_rel(rel);
    if c.head_only || size == 0 {
        // No file bytes: normal emit path with explicit Content-Length.
        c.status = 200;
        c.ctype = mime;
        c.resp_body = "";
        c.resp_len = size;
        c.responded = true;
        honk_file_close(fd);
        return true;
    }
    // GET with bytes: headers join tx_buf in order; file follows via sendfile.
    let hstart = c.res.len;
    c.res.append("HTTP/1.1 200 OK\r\nContent-Type: ");
    c.res.append(mime);
    c.res.append("\r\nDate: ");
    c.res.append(c.date);
    if !c.keep_alive {
        c.res.append("\r\nConnection: close");
    }
    c.res.append("\r\nContent-Length: ");
    format(c.res, size);
    c.res.append("\r\n\r\n");
    c.resp_hdrs = c.res[hstart..];
    c.resp_file_fd = fd;
    c.resp_file_n = size;
    c.status = 200;
    c.responded = true;
    c.sent = true;
    return true;
}

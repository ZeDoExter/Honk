// honk_static.goose -- zero-copy static file serving (`sendfile` + `ETag`/`304`
// + compile-time `embed_file` single-binary asset serving).

import std;
import src.honk_ctx.honk_ctx;

// App-level directory mount: GET/HEAD under prefix served from root with ETag/304.
inline fn static_dir(app: honk::Ctx&, prefix: const u8[:], root: const u8[:]) {
    static_dir_cached(app, prefix, root, "");
}

// Directory mount with explicit `Cache-Control` header (e.g. `"public, max-age=3600"`).
inline fn static_dir_cached(app: honk::Ctx&, prefix: const u8[:], root: const u8[:], cache_ctl: const u8[:]) {
    if app.handled { return; }
    if prefix == "/" {
        if app.path.len == 0 || app.path[0] != '/' { return; }
        app.path_matched = true;
        if app.method != "GET" && !app.head_only { return; }
        if serve_rel_cached(app, root, app.path[1..], true, cache_ctl) { app.handled = true; }
        return;
    }
    let rest, ok = app.rest(prefix);
    if !ok { return; }
    app.path_matched = true;
    if app.method != "GET" && !app.head_only { return; }
    if serve_rel_cached(app, root, rest, true, cache_ctl) { app.handled = true; }
}

// Serve compile-time `embed_file(...)` bytes at `route` with deterministic
// FNV-1a `ETag` + `304 Not Modified` support (ships SPAs inside one binary).
inline fn embed(app: honk::Ctx&, route: const u8[:], data: const u8[:],
                mime: const u8[:] = "", cache_ctl: const u8[:] = "") {
    if app.handled { return; }
    if app.path == route { app.path_matched = true; }
    if (app.method != "GET" && !app.head_only) || app.path != route { return; }

    var h: u64 = 14695981039346656037;
    for b in data {
        h = (h ^ b) * 1099511628211;
    }
    let estart = app.tmp.len;
    app.tmp.append("\"");
    format(app.tmp, data.len);
    app.tmp.push('-');
    format(app.tmp, (h & 9223372036854775807) as! i64);
    app.tmp.push('"');
    let etag = app.tmp[estart..];

    app.set_header("ETag", etag);
    if cache_ctl.len > 0 {
        app.set_header("Cache-Control", cache_ctl);
    }
    let ctype = if mime.len > 0 { mime } else { mime_for_rel(route) };
    let inm, has_inm = app.header("If-None-Match");
    if has_inm && (inm == etag || inm == "*") {
        app.status = 304;
        app.ctype = ctype;
        app.resp_body = "";
        app.resp_len = 0;
        app.responded = true;
    } else {
        app.status = 200;
        app.ctype = ctype;
        app.resp_body = data;
        app.responded = true;
    }
    app.handled = true;
}

extern fn honk_file_open(root: const u8[:], rel: const u8[:]) -> i32;
extern fn honk_file_size(file_fd: i32) -> i64;
extern fn honk_file_mtime(file_fd: i32) -> i64;
extern fn honk_file_close(file_fd: i32);

inline fn ext_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for k in a.len {
        if !honk::eq_ci(a[k], b[k]) { return false; }
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

fn try_serve_file(c: honk::Ctx&, root: const u8[:], with_index: bool) -> bool {
    if c.method != "GET" && !c.head_only {
        c.text(405, "Method Not Allowed");
        return true;
    }
    if root.len == 0 || c.path.len == 0 || c.path[0] != '/' {
        return false;
    }
    return serve_rel_cached(c, root, c.path[1..], with_index, "");
}

fn serve_rel(c: honk::Ctx&, root: const u8[:], raw: const u8[:], with_index: bool) -> bool {
    return serve_rel_cached(c, root, raw, with_index, "");
}

fn serve_rel_cached(c: honk::Ctx&, root: const u8[:], raw: const u8[:],
                    with_index: bool, cache_ctl: const u8[:]) -> bool {
    if root.len == 0 { return false; }
    for ch in raw {
        if ch == 0 || ch == '\\' { return false; }
    }
    let dec, ok = honk::url_decode(c, raw, false);
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
                return false;
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
    let mtime = honk_file_mtime(fd);
    let mime = mime_for_rel(rel);

    let estart = c.tmp.len;
    c.tmp.append("W/\"");
    format(c.tmp, size);
    c.tmp.push('-');
    format(c.tmp, mtime);
    c.tmp.push('"');
    let etag = c.tmp[estart..];

    let inm, has_inm = c.header("If-None-Match");
    if has_inm && (inm == etag || inm == "*") {
        c.set_header("ETag", etag);
        if cache_ctl.len > 0 { c.set_header("Cache-Control", cache_ctl); }
        c.status = 304;
        c.ctype = mime;
        c.resp_body = "";
        c.resp_len = 0;
        c.responded = true;
        honk_file_close(fd);
        return true;
    }

    if c.head_only || size == 0 {
        c.set_header("ETag", etag);
        if cache_ctl.len > 0 { c.set_header("Cache-Control", cache_ctl); }
        c.status = 200;
        c.ctype = mime;
        c.resp_body = "";
        c.resp_len = size;
        c.responded = true;
        honk_file_close(fd);
        return true;
    }

    let hstart = c.res.len;
    c.res.append("HTTP/1.1 200 OK\r\nContent-Type: ");
    c.res.append(mime);
    c.res.append("\r\nDate: ");
    c.res.append(c.date);
    c.res.append("\r\nETag: ");
    c.res.append(etag);
    if cache_ctl.len > 0 {
        c.res.append("\r\nCache-Control: ");
        c.res.append(cache_ctl);
    }
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

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
    app.set_header("Accept-Ranges", "bytes");
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
        let rg, has_rg = app.header("Range");
        // Embed ETags are strong: an exact echo keeps the range; anything else
        // (dates included — embeds carry no mtime) falls back to 200.
        let irv_e, has_irv_e = app.header("If-Range");
        let range_ok_e = if !has_irv_e { true } else { irv_e == etag };
        if has_rg && range_ok_e {
            let rs, re, rok, runsat = parse_range(rg, data.len);
            if runsat {
                let ustart = app.tmp.len;
                app.tmp.append("bytes */");
                format(app.tmp, data.len);
                app.set_header("Content-Range", app.tmp[ustart..]);
                app.status = 416;
                app.ctype = ctype;
                app.resp_body = "";
                app.resp_len = 0;
                app.responded = true;
            } else if rok {
                let rstart = app.tmp.len;
                app.tmp.append("bytes ");
                format(app.tmp, rs);
                app.tmp.push('-');
                format(app.tmp, re);
                app.tmp.push('/');
                format(app.tmp, data.len);
                app.set_header("Content-Range", app.tmp[rstart..]);
                app.status = 206;
                app.ctype = ctype;
                app.resp_body = data[rs..re + 1];
                app.responded = true;
            } else {
                app.status = 200;
                app.ctype = ctype;
                app.resp_body = data;
                app.responded = true;
            }
        } else {
            app.status = 200;
            app.ctype = ctype;
            app.resp_body = data;
            app.responded = true;
        }
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
    if ext_eq(ext, "woff") { return "font/woff"; }
    if ext_eq(ext, "mp4") { return "video/mp4"; }
    if ext_eq(ext, "webm") { return "video/webm"; }
    if ext_eq(ext, "ogv") { return "video/ogg"; }
    if ext_eq(ext, "mp3") { return "audio/mpeg"; }
    if ext_eq(ext, "wav") { return "audio/wav"; }
    if ext_eq(ext, "ogg") { return "audio/ogg"; }
    if ext_eq(ext, "avif") { return "image/avif"; }
    if ext_eq(ext, "gif") { return "image/gif"; }
    if ext_eq(ext, "pdf") { return "application/pdf"; }
    if ext_eq(ext, "xml") { return "application/xml"; }
    return "application/octet-stream";
}

// Format unix epoch seconds as an RFC 9110 IMF-fixdate
// (`Sun, 06 Nov 1994 08:49:37 GMT`). Pure Goose (Howard Hinnant
// civil_from_days), no FFI; clamps negative input to the epoch.
fn http_date(mtime: i64, out: u8[>..]&) -> const u8[:] {
    let t = if mtime > 0 { mtime } else { 0 };
    let days = t / 86400;
    let secs = t % 86400;
    let hh = secs / 3600;
    let mm = (secs % 3600) / 60;
    let ss = secs % 60;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    var m = mp + 3;
    if mp >= 10 { m = mp - 9; y++; }
    let wday = (days + 4) % 7;
    let wdays = "SunMonTueWedThuFriSat";
    let months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    let start = out.len;
    out.append(wdays[wday * 3 .. wday * 3 + 3]);
    out.append(", ");
    if d < 10 { out.push('0'); }
    format(out, d);
    out.push(' ');
    out.append(months[(m - 1) * 3 .. (m - 1) * 3 + 3]);
    out.push(' ');
    format(out, y);
    out.push(' ');
    if hh < 10 { out.push('0'); }
    format(out, hh);
    out.push(':');
    if mm < 10 { out.push('0'); }
    format(out, mm);
    out.push(':');
    if ss < 10 { out.push('0'); }
    format(out, ss);
    out.append(" GMT");
    return out[start..];
}
// Parse a single `Range: bytes=<s>-<e>` / `<s>-` / `-<suffix>` against `size`.
// Returns (start, end_inclusive, ok, unsatisfiable): malformed, unit-mismatch,
// or multi-range input yields ok=false (caller serves 200). Unsatisfiable
// (start >= size, start > end, `-0`, or any range on an empty representation)
// yields unsatisfiable=true (caller serves 416). Endpoints clamp to `size - 1`.
fn parse_range(hdr: const u8[:], size: i64) -> i64, i64, bool, bool {
    var p: i64 = 0;
    while p < hdr.len && (hdr[p] == ' ' || hdr[p] == '\t') { p++; }
    if p + 5 > hdr.len { return 0, 0, false, false; }
    let unit = "bytes";
    for k in 5 {
        if !honk::eq_ci(hdr[p + k], unit[k]) { return 0, 0, false, false; }
    }
    p += 5;
    while p < hdr.len && (hdr[p] == ' ' || hdr[p] == '\t') { p++; }
    if p >= hdr.len || hdr[p] != '=' { return 0, 0, false, false; }
    p++;
    while p < hdr.len && (hdr[p] == ' ' || hdr[p] == '\t') { p++; }
    for ch in hdr[p..] {
        if ch == ',' { return 0, 0, false, false; }
    }
    var has_start = false;
    var start: i64 = 0;
    while p < hdr.len && hdr[p] >= '0' && hdr[p] <= '9' {
        has_start = true;
        let d: i64 = hdr[p] - '0';
        if start > (9223372036854775807 - d) / 10 { start = 9223372036854775807; }
        else { start = start * 10 + d; }
        p++;
    }
    if p >= hdr.len || hdr[p] != '-' { return 0, 0, false, false; }
    p++;
    var has_end = false;
    var end: i64 = 0;
    while p < hdr.len && hdr[p] >= '0' && hdr[p] <= '9' {
        has_end = true;
        let d: i64 = hdr[p] - '0';
        if end > (9223372036854775807 - d) / 10 { end = 9223372036854775807; }
        else { end = end * 10 + d; }
        p++;
    }
    while p < hdr.len && (hdr[p] == ' ' || hdr[p] == '\t') { p++; }
    if p != hdr.len { return 0, 0, false, false; }
    if size <= 0 { return 0, 0, false, true; }
    if !has_start && !has_end { return 0, 0, false, false; }
    if !has_start {
        if end <= 0 { return 0, 0, false, true; }
        let n = if end > size { size } else { end };
        return size - n, size - 1, true, false;
    }
    if start >= size { return 0, 0, false, true; }
    let e = if !has_end || end >= size { size - 1 } else { end };
    if e < start { return 0, 0, false, true; }
    return start, e, true, false;
}
inline fn digits2(s: const u8[:], o: i64) -> i64, bool {
    if s[o] < '0' || s[o] > '9' || s[o + 1] < '0' || s[o + 1] > '9' { return 0, false; }
    return (s[o] - '0') * 10 + (s[o + 1] - '0'), true;
}

// Parse an RFC 9110 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) to unix
// epoch seconds (pure Goose, inverse of `http_date`). Strict 29-byte shape;
// false on any deviation. Years before 1970 clamp to the epoch.
fn parse_imf_date(s: const u8[:]) -> i64, bool {
    if s.len != 29 { return 0, false; }
    for k in 3 {
        if !ascii::is_alpha(s[k]) { return 0, false; }
    }
    if s[3] != ',' || s[4] != ' ' { return 0, false; }
    if s[7] != ' ' || s[11] != ' ' || s[16] != ' ' { return 0, false; }
    if s[19] != ':' || s[22] != ':' { return 0, false; }
    if s[25] != ' ' || s[26] != 'G' || s[27] != 'M' || s[28] != 'T' { return 0, false; }
    let d, dok = digits2(s, 5);
    let hh, hok = digits2(s, 17);
    let mm, mok = digits2(s, 20);
    let ss, sok = digits2(s, 23);
    if !dok || !hok || !mok || !sok { return 0, false; }
    var y: i64 = 0;
    var yi: i64 = 12;
    while yi < 16 {
        if s[yi] < '0' || s[yi] > '9' { return 0, false; }
        y = y * 10 + (s[yi] - '0');
        yi++;
    }
    let months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    var m: i64 = 0;
    var mi: i64 = 0;
    while mi < 12 {
        if s[8] == months[mi * 3] && s[9] == months[mi * 3 + 1] && s[10] == months[mi * 3 + 2] {
            m = mi + 1;
            break;
        }
        mi++;
    }
    if m == 0 { return 0, false; }
    if d < 1 || d > 31 || hh > 23 || mm > 59 || ss > 59 { return 0, false; }
    if y < 1970 { return 0, true; }
    var yy = y;
    if m <= 2 { yy--; }
    let era = yy / 400;
    let yoe = yy - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss, true;
}
// Case-insensitive `Accept-Encoding` token match with `q=0` refusal honored
// (`gzip;q=0` does NOT match). Longer tokens sharing the prefix don't match.
fn ae_has_token(hdr: const u8[:], tok: const u8[:]) -> bool {
    if hdr.len < tok.len { return false; }
    var i: i64 = 0;
    while i + tok.len <= hdr.len {
        var ok = true;
        for k in tok.len {
            if !honk::eq_ci(hdr[i + k], tok[k]) { ok = false; break; }
        }
        if ok {
            let left_ok = i == 0 || hdr[i - 1] == ' ' || hdr[i - 1] == '\t' || hdr[i - 1] == ',';
            if left_ok {
                var r = i + tok.len;
                while r < hdr.len && (hdr[r] == ' ' || hdr[r] == '\t') { r++; }
                if r >= hdr.len || hdr[r] == ',' { return true; }
                if hdr[r] == ';' {
                    var q = r;
                    var refused = false;
                    while q < hdr.len && hdr[q] != ',' {
                        if (hdr[q] == 'q' || hdr[q] == 'Q') && q + 1 < hdr.len && hdr[q + 1] == '=' {
                            var v = q + 2;
                            while v < hdr.len && (hdr[v] == ' ' || hdr[v] == '\t') { v++; }
                            if v < hdr.len && hdr[v] == '0' {
                                var w = v + 1;
                                var allzero = true;
                                if w < hdr.len && hdr[w] == '.' {
                                    w++;
                                    while w < hdr.len && hdr[w] >= '0' && hdr[w] <= '9' {
                                        if hdr[w] != '0' { allzero = false; }
                                        w++;
                                    }
                                }
                                if allzero { refused = true; }
                            }
                        }
                        q++;
                    }
                    if !refused { return true; }
                }
            }
        }
        i++;
    }
    return false;
}
// True for MIME types worth precompressing (text, JSON/XML, SVG, WASM).
// Media, fonts, and archives are already compressed: probing sidecars for
// them would only waste openat syscalls.
inline fn mime_is_compressible(m: const u8[:]) -> bool {
    if m.len >= 5 && m[..5] == "text/" { return true; }
    if m == "application/json" { return true; }
    if m == "image/svg+xml" { return true; }
    if m == "application/xml" { return true; }
    if m == "application/wasm" { return true; }
    return false;
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
    // Precompressed variants: prefer `rel.br`, then `rel.gz`, when the client
    // accepts them (identity fallback otherwise; Range always uses identity).
    // Only probed for compressible types (skips wasted openat on media/fonts);
    // variant ETags carry a `-br`/`-gz` suffix; MIME stays original.
    let mime_early = mime_for_rel(rel);
    var enc: const u8[:] = "";
    var fd: i32 = -1;
    let ae, has_ae = c.header("Accept-Encoding");
    let rg0, has_rg0 = c.header("Range");
    if !has_rg0 && has_ae && mime_is_compressible(mime_early) {
        if ae_has_token(ae, "br") {
            var cand: u8[>..] = [];
            cand.append(rel);
            cand.append(".br");
            fd = honk_file_open(root, cand[..]);
            if fd >= 0 { enc = "br"; }
        }
        if fd < 0 && ae_has_token(ae, "gzip") {
            var cand: u8[>..] = [];
            cand.append(rel);
            cand.append(".gz");
            fd = honk_file_open(root, cand[..]);
            if fd >= 0 { enc = "gzip"; }
        }
    }
    if fd < 0 {
        fd = honk_file_open(root, rel);
    }
    if fd < 0 { return false; }
    let size = honk_file_size(fd);
    if size < 0 {
        honk_file_close(fd);
        return false;
    }
    let mtime = honk_file_mtime(fd);
    let mime = mime_early;

    let estart = c.tmp.len;
    c.tmp.append("W/\"");
    format(c.tmp, size);
    c.tmp.push('-');
    format(c.tmp, mtime);
    if enc == "br" { c.tmp.append("-br"); }
    else if enc == "gzip" { c.tmp.append("-gz"); }
    c.tmp.push('"');
    let etag = c.tmp[estart..];
    let lm = http_date(mtime, c.tmp);

    let inm, has_inm = c.header("If-None-Match");
    if has_inm && (inm == etag || inm == "*") {
        c.set_header("ETag", etag);
        c.set_header("Last-Modified", lm);
        c.set_header("Vary", "Accept-Encoding");
        if enc.len > 0 { c.set_header("Content-Encoding", enc); }
        if cache_ctl.len > 0 { c.set_header("Cache-Control", cache_ctl); }
        c.status = 304;
        c.ctype = mime;
        c.resp_body = "";
        c.resp_len = 0;
        c.responded = true;
        honk_file_close(fd);
        return true;
    }

    // RFC 9110 §13.2.2: If-None-Match present -> evaluate ETag ONLY, ignore IMS.
    let ims, has_ims = c.header("If-Modified-Since");
    if has_ims && !has_inm {
        let it, iok = parse_imf_date(ims);
        if iok && mtime <= it {
            c.set_header("ETag", etag);
            c.set_header("Last-Modified", lm);
            c.set_header("Vary", "Accept-Encoding");
            if enc.len > 0 { c.set_header("Content-Encoding", enc); }
            if cache_ctl.len > 0 { c.set_header("Cache-Control", cache_ctl); }
            c.status = 304;
            c.ctype = mime;
            c.resp_body = "";
            c.resp_len = 0;
            c.responded = true;
            honk_file_close(fd);
            return true;
        }
    }

    // Single-range request? Invalid/multi-range falls back to 200 below;
    // unsatisfiable short-circuits 416 here (INM/304 above takes precedence).
    var rs: i64 = 0;
    var re: i64 = -1;
    var has_range = false;
    let rg, has_rg = c.header("Range");
    // If-Range gate: file ETags are weak (`W/…`), which per RFC 9110 §13.1.2
    // never matches If-Range — only an exact Last-Modified date keeps the range.
    var range_ok = true;
    let irv, has_irv = c.header("If-Range");
    if has_irv {
        range_ok = false;
        if irv.len > 0 && irv[0] != '"' && !(irv.len > 2 && irv[0] == 'W' && irv[1] == '/') {
            let it2, iok2 = parse_imf_date(irv);
            if iok2 && it2 == mtime { range_ok = true; }
        }
    }
    if has_rg && range_ok {
        let ps, pe, pok, punsat = parse_range(rg, size);
        if punsat {
            let cstart = c.tmp.len;
            c.tmp.append("bytes */");
            format(c.tmp, size);
            c.set_header("Content-Range", c.tmp[cstart..]);
            c.set_header("Accept-Ranges", "bytes");
            c.set_header("Vary", "Accept-Encoding");
            c.set_header("ETag", etag);
            c.status = 416;
            c.ctype = mime;
            c.resp_body = "";
            c.resp_len = 0;
            c.responded = true;
            honk_file_close(fd);
            return true;
        }
        if pok {
            rs = ps;
            re = pe;
            has_range = true;
        }
    }

    if c.head_only || size == 0 {
        c.set_header("ETag", etag);
        c.set_header("Last-Modified", lm);
        c.set_header("Accept-Ranges", "bytes");
        c.set_header("Vary", "Accept-Encoding");
        if enc.len > 0 { c.set_header("Content-Encoding", enc); }
        if cache_ctl.len > 0 { c.set_header("Cache-Control", cache_ctl); }
        if has_range {
            let rstart = c.tmp.len;
            c.tmp.append("bytes ");
            format(c.tmp, rs);
            c.tmp.push('-');
            format(c.tmp, re);
            c.tmp.push('/');
            format(c.tmp, size);
            c.set_header("Content-Range", c.tmp[rstart..]);
            c.status = 206;
            c.resp_len = re - rs + 1;
        } else {
            c.status = 200;
            c.resp_len = size;
        }
        c.ctype = mime;
        c.resp_body = "";
        c.responded = true;
        honk_file_close(fd);
        return true;
    }

    let hstart = c.res.len;
    if has_range {
        c.res.append("HTTP/1.1 206 Partial Content\r\nContent-Type: ");
    } else {
        c.res.append("HTTP/1.1 200 OK\r\nContent-Type: ");
    }
    c.res.append(mime);
    c.res.append("\r\nDate: ");
    c.res.append(c.date);
    c.res.append("\r\nETag: ");
    c.res.append(etag);
    c.res.append("\r\nLast-Modified: ");
    c.res.append(lm);
    c.res.append("\r\nAccept-Ranges: bytes");
    c.res.append("\r\nVary: Accept-Encoding");
    if enc.len > 0 {
        c.res.append("\r\nContent-Encoding: ");
        c.res.append(enc);
    }
    if has_range {
        c.res.append("\r\nContent-Range: bytes ");
        format(c.res, rs);
        c.res.push('-');
        format(c.res, re);
        c.res.push('/');
        format(c.res, size);
    }
    if cache_ctl.len > 0 {
        c.res.append("\r\nCache-Control: ");
        c.res.append(cache_ctl);
    }
    if !c.keep_alive {
        c.res.append("\r\nConnection: close");
    }
    let body_n = if has_range { re - rs + 1 } else { size };
    c.res.append("\r\nContent-Length: ");
    format(c.res, body_n);
    c.res.append("\r\n\r\n");
    c.resp_hdrs = c.res[hstart..];
    c.resp_file_fd = fd;
    c.resp_file_off = if has_range { rs } else { 0 };
    c.resp_file_n = body_n;
    c.status = if has_range { 206 } else { 200 };
    c.responded = true;
    c.sent = true;
    return true;
}

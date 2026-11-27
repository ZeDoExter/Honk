// honk_gzip.goose -- opt-in dynamic gzip for response bodies (system zlib).
//
// Declared beside honk_gzip.build so apps need no .build file of their own:
//   import honk from "../..";
//   import honk_gzip from "../../gzip";
//
// Explicit per-route compression: `ctx.json_gz(200, body)` sends gzip only
// when the body clears `threshold` (default 1024 bytes) AND the client sent
// `Accept-Encoding: gzip` — otherwise it degrades to the plain stager with
// zero extra cost. Apps that never import this link neither the shim nor -lz.
//
// Prefer precompressed `.br`/`.gz` sidecars for static files (zero per-request
// CPU); use these helpers for dynamic bodies (JSON APIs, rendered HTML).
// Compression level is zlib's default (6); one malloc/free per response.

import std;
import honk from "..";

extern fn hgz_deflate(src: const u8[:], out: u8[>..]&) -> i64;

// Case-insensitive 4-byte token match (needle must be lowercase alpha).
fn gz_tok_is(tok: const u8[:], a: u8, b: u8, c: u8, d: u8) -> bool {
    if tok.len != 4 { return false; }
    return (tok[0] | 32) == a && (tok[1] | 32) == b && (tok[2] | 32) == c && (tok[3] | 32) == d;
}

// True when the request's Accept-Encoding allows gzip: explicit token match
// (case-insensitive), honoring a `q=0` refusal on that token.
fn wants_gzip(app: honk::Ctx&) -> bool {
    let v, ok = app.header("Accept-Encoding");
    if !ok { return false; }
    var i: i64 = 0;
    while i < v.len {
        while i < v.len && (v[i] == ' ' || v[i] == '\t') { i++; }
        let ts = i;
        while i < v.len && v[i] != ',' && v[i] != ';' { i++; }
        var te = i;
        while te > ts && (v[te - 1] == ' ' || v[te - 1] == '\t') { te--; }
        var refused = false;
        if i < v.len && v[i] == ';' {
            var j = i;
            while j < v.len && v[j] != ',' {
                if (v[j] == 'q' || v[j] == 'Q') && j + 1 < v.len && v[j + 1] == '=' {
                    var k = j + 2;
                    while k < v.len && (v[k] == ' ' || v[k] == '\t') { k++; }
                    if k < v.len && v[k] == '0' {
                        var m = k + 1;
                        var allzero = true;
                        if m < v.len && v[m] == '.' {
                            m++;
                            let fs = m;
                            while m < v.len && v[m] >= '0' && v[m] <= '9' {
                                if v[m] != '0' { allzero = false; }
                                m++;
                            }
                            if m == fs { allzero = false; }
                        }
                        if allzero { refused = true; }
                    }
                }
                j++;
            }
            while i < v.len && v[i] != ',' { i++; }
        }
        if !refused && gz_tok_is(v[ts..te], 'g', 'z', 'i', 'p') { return true; }
        if i < v.len && v[i] == ',' { i++; }
    }
    return false;
}

// Compression core: gzip bytes into app.tmp, materialize into app.res.
// Returns the app.res offset of the compressed body, or -1 when identity
// was chosen (under threshold, client refused, header room, shim failure).
// Never fails the request — identity is the fallback.
inline fn gz_prep(app: honk::Ctx&, s: const u8[:], threshold: i64) -> i64 {
    if s.len <= 0 || s.len < threshold { return -1; }
    if app.n_extra + 2 > 16 { return -1; }
    if !wants_gzip(app) { return -1; }
    let tstart = app.tmp.len;
    if hgz_deflate(s, app.tmp) <= 0 { return -1; }
    let rstart = app.res.len;
    app.res.append(app.tmp[tstart..]);
    app.set_header("Content-Encoding", "gzip");
    app.set_header("Vary", "Accept-Encoding");
    return rstart;
}

// Stage a JSON response, gzipped when worthwhile and accepted. Always
// materializes the body into the response buffer (one copy on identity —
// required for soundness since handler-local slices die at handler exit).
inline fn json_gz(app: honk::Ctx&, status: i64, s: const u8[:], threshold: i64 = 1024) {
    let r = gz_prep(app, s, threshold);
    if r >= 0 {
        app.json_raw(status, app.res[r..]);
    } else {
        let rstart = app.res.len;
        app.res.append(s);
        app.json_raw(status, app.res[rstart..]);
    }
}

// Stage a plain-text response, gzipped when worthwhile and accepted.
inline fn text_gz(app: honk::Ctx&, status: i64, s: const u8[:], threshold: i64 = 1024) {
    let r = gz_prep(app, s, threshold);
    if r >= 0 {
        app.text(status, app.res[r..]);
    } else {
        let rstart = app.res.len;
        app.res.append(s);
        app.text(status, app.res[rstart..]);
    }
}

// Stage an HTML response, gzipped when worthwhile and accepted.
inline fn html_gz(app: honk::Ctx&, status: i64, s: const u8[:], threshold: i64 = 1024) {
    let r = gz_prep(app, s, threshold);
    if r >= 0 {
        app.html(status, app.res[r..]);
    } else {
        let rstart = app.res.len;
        app.res.append(s);
        app.html(status, app.res[rstart..]);
    }
}

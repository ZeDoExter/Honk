// honk_auth.goose -- zero-dependency SHA-256, HMAC-SHA256, Base64URL, JWT (HS256),
// and HMAC-signed cookies (`honk::` namespace).
//
// Opt-in submodule (`import honk.src.honk_auth.honk_auth;`): 100% pure Goose,
// zero OpenSSL/libcrypto dependency, and zero bytes compiled into binaries
// that do not import it.

namespace honk;

import std;
import json;
import src.honk_net.honk_net;
import src.honk_ctx.honk_ctx;

inline fn rotr32(x: u32, n: u32) -> u32 {
    return (x >> n) | (x << (32 - n));
}

// FIPS 180-4 SHA-256 digest (32 bytes, zero heap allocations).
fn sha256(msg: const u8[:]) -> u8[32] {
    let k: u32[64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    var h0: u32 = 0x6a09e667;
    var h1: u32 = 0xbb67ae85;
    var h2: u32 = 0x3c6ef372;
    var h3: u32 = 0xa54ff53a;
    var h4: u32 = 0x510e527f;
    var h5: u32 = 0x9b05688c;
    var h6: u32 = 0x1f83d9ab;
    var h7: u32 = 0x5be0cd19;

    let bit_len: u64 = (msg.len as! u64) * 8;
    // Total padded bytes: msg.len + 1 + pad_zeros + 8, multiple of 64.
    let rem = (msg.len + 9) % 64;
    let total = msg.len + 9 + (if rem == 0 { 0 } else { 64 - rem });
    let nblocks = total / 64;

    var blk: u8[64] = [0; 64];
    var w: u32[64] = [0; 64];

    for b_idx in nblocks {
        let base = b_idx * 64;
        for j in 64 {
            let pos = base + j;
            if pos < msg.len {
                blk[j] = msg[pos];
            } else if pos == msg.len {
                blk[j] = 0x80;
            } else if pos >= total - 8 {
                let shift: u64 = ((total - 1 - pos) as! u64) * 8;
                blk[j] = ((bit_len >> shift) & 0xff) as! u8;
            } else {
                blk[j] = 0;
            }
        }

        for i in 16 {
            let o = i * 4;
            w[i] = ((blk[o] as! u32) << 24)
                 | ((blk[o + 1] as! u32) << 16)
                 | ((blk[o + 2] as! u32) << 8)
                 | blk[o + 3];
        }
        var i: i64 = 16;
        while i < 64 {
            let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
            let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            i++;
        }

        var a = h0;
        var b = h1;
        var c = h2;
        var d = h3;
        var e = h4;
        var f = h5;
        var g = h6;
        var hh = h7;

        for t in 64 {
            let sig1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
            let ch = (e & f) ^ ((~e) & g);
            let temp1 = hh + sig1 + ch + k[t] + w[t];
            let sig0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = sig0 + maj;

            hh = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }

        h0 = h0 + a;
        h1 = h1 + b;
        h2 = h2 + c;
        h3 = h3 + d;
        h4 = h4 + e;
        h5 = h5 + f;
        h6 = h6 + g;
        h7 = h7 + hh;
    }

    let words: u32[8] = [h0, h1, h2, h3, h4, h5, h6, h7];
    var out: u8[32] = [0; 32];
    for idx in 8 {
        let v = words[idx];
        let o = idx * 4;
        out[o] = ((v >> 24) & 0xff) as! u8;
        out[o + 1] = ((v >> 16) & 0xff) as! u8;
        out[o + 2] = ((v >> 8) & 0xff) as! u8;
        out[o + 3] = (v & 0xff) as! u8;
    }
    return out;
}

// RFC 2104 HMAC-SHA256 (32-byte MAC, scoped builder for inner message).
fn hmac_sha256(key: const u8[:], msg: const u8[:]) -> u8[32] {
    var kblock: u8[64] = [0; 64];
    if key.len > 64 {
        let kh = sha256(key);
        for i in 32 { kblock[i] = kh[i]; }
    } else {
        for i in key.len { kblock[i] = key[i]; }
    }
    var inner: u8[>..] = [];
    for i in 64 { inner.push(kblock[i] ^ 0x36); }
    inner.append(msg);
    let ih = sha256(inner[..]);

    var outer: u8[96] = [0; 96];
    for i in 64 { outer[i] = kblock[i] ^ 0x5c; }
    for i in 32 { outer[64 + i] = ih[i]; }
    return sha256(outer[..]);
}

// Constant-time slice equality (prevents timing side-channels on MAC checks).
fn ct_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    var diff: u8 = 0;
    for i in a.len {
        diff = diff | (a[i] ^ b[i]);
    }
    return diff == 0;
}

// RFC 4648 §5 Base64URL encode without '=' padding.
fn b64url_encode(src: const u8[:], out: u8[>..]&) -> const u8[:] {
    let alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let start = out.len;
    var i: i64 = 0;
    while i + 3 <= src.len {
        let v = ((src[i] as! u32) << 16) | ((src[i + 1] as! u32) << 8) | src[i + 2];
        out.push(alpha[((v >> 18) & 63) as! i64]);
        out.push(alpha[((v >> 12) & 63) as! i64]);
        out.push(alpha[((v >> 6) & 63) as! i64]);
        out.push(alpha[(v & 63) as! i64]);
        i += 3;
    }
    let rem = src.len - i;
    if rem == 1 {
        let v = (src[i] as! u32) << 16;
        out.push(alpha[((v >> 18) & 63) as! i64]);
        out.push(alpha[((v >> 12) & 63) as! i64]);
    } else if rem == 2 {
        let v = ((src[i] as! u32) << 16) | ((src[i + 1] as! u32) << 8);
        out.push(alpha[((v >> 18) & 63) as! i64]);
        out.push(alpha[((v >> 12) & 63) as! i64]);
        out.push(alpha[((v >> 6) & 63) as! i64]);
    }
    return out[start..];
}

inline fn b64url_val(c: u8) -> i32 {
    if c >= 'A' && c <= 'Z' { return c - 'A'; }
    if c >= 'a' && c <= 'z' { return (c - 'a') + 26; }
    if c >= '0' && c <= '9' { return (c - '0') + 52; }
    if c == '-' { return 62; }
    if c == '_' { return 63; }
    return -1;
}

// RFC 4648 §5 Base64URL decode (accepts unpadded or '='-padded input).
fn b64url_decode(src: const u8[:], out: u8[>..]&) -> const u8[:], bool {
    var slen = src.len;
    while slen > 0 && src[slen - 1] == '=' { slen--; }
    if slen % 4 == 1 { return "", false; }
    let start = out.len;
    var i: i64 = 0;
    while i + 4 <= slen {
        let a = b64url_val(src[i]);
        let b = b64url_val(src[i + 1]);
        let c = b64url_val(src[i + 2]);
        let d = b64url_val(src[i + 3]);
        if a < 0 || b < 0 || c < 0 || d < 0 { return "", false; }
        let v = (a << 18) | (b << 12) | (c << 6) | d;
        out.push(((v >> 16) & 0xff) as! u8);
        out.push(((v >> 8) & 0xff) as! u8);
        out.push((v & 0xff) as! u8);
        i += 4;
    }
    let rem = slen - i;
    if rem == 2 {
        let a = b64url_val(src[i]);
        let b = b64url_val(src[i + 1]);
        if a < 0 || b < 0 { return "", false; }
        let v = (a << 18) | (b << 12);
        out.push(((v >> 16) & 0xff) as! u8);
    } else if rem == 3 {
        let a = b64url_val(src[i]);
        let b = b64url_val(src[i + 1]);
        let c = b64url_val(src[i + 2]);
        if a < 0 || b < 0 || c < 0 { return "", false; }
        let v = (a << 18) | (b << 12) | (c << 6);
        out.push(((v >> 16) & 0xff) as! u8);
        out.push(((v >> 8) & 0xff) as! u8);
    }
    return out[start..], true;
}

// Sign `payload_json` as an RFC 7519 HS256 JWT into `out`.
fn jwt_sign(payload_json: const u8[:], secret: const u8[:], out: u8[>..]&) -> const u8[:] {
    let start = out.len;
    // Base64URL({"alg":"HS256","typ":"JWT"})
    out.append("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.");
    b64url_encode(payload_json, out);
    let mac = hmac_sha256(secret, out[start..]);
    out.push('.');
    b64url_encode(mac[..], out);
    return out[start..];
}

// Verify an HS256 JWT (rejects non-HS256 headers, bad MACs, malformed JSON,
// expired `exp`, and premature `nbf`). Returns decoded payload JSON slice.
fn jwt_verify(token: const u8[:], secret: const u8[:], scratch: u8[>..]&) -> const u8[:], bool {
    var d1 = -1;
    var d2 = -1;
    for ch, i in token {
        if ch == '.' {
            if d1 < 0 { d1 = i; }
            else if d2 < 0 { d2 = i; }
            else { return "", false; }
        }
    }
    if d1 <= 0 || d2 <= d1 + 1 || d2 + 1 >= token.len { return "", false; }

    let hdr_b64 = token[..d1];
    let pay_b64 = token[d1 + 1 .. d2];
    let sig_b64 = token[d2 + 1 ..];

    // Constant-time MAC verification FIRST before parsing untrusted JSON.
    let mac = hmac_sha256(secret, token[..d2]);
    var sig_tmp: u8[>..] = [];
    let want_sig = b64url_encode(mac[..], sig_tmp);
    if !ct_eq(sig_b64, want_sig) { return "", false; }

    var hdr_dec_buf: u8[>..] = [];
    let hdr_json, hok = b64url_decode(hdr_b64, hdr_dec_buf);
    if !hok { return "", false; }

    var doc: json::Node[>..] = [];
    var dstr: u8[>..] = [];
    let hroot, _he = json::parse(hdr_json, doc, dstr);
    if !hroot { return "", false; }
    let alg, aok = json::as_string(json::member(hroot, "alg"));
    if !aok || alg != "HS256" { return "", false; }

    let payload_json, pok = b64url_decode(pay_b64, scratch);
    if !pok { return "", false; }

    var pdoc: json::Node[>..] = [];
    var pdstr: u8[>..] = [];
    let proot, _pe = json::parse(payload_json, pdoc, pdstr);
    if !proot { return "", false; }

    let now = honk_unix_sec();
    let exp_node = json::member(proot, "exp");
    if exp_node {
        let exp, eok = json::as_i64(exp_node);
        if !eok || exp <= now { return "", false; }
    }
    let nbf_node = json::member(proot, "nbf");
    if nbf_node {
        let nbf, nok = json::as_i64(nbf_node);
        if !nok || nbf > now { return "", false; }
    }
    return payload_json, true;
}

// Issue a standard `{"sub":...,"iat":...,"exp":...}` HS256 JWT into `app.tmp`.
fn jwt_issue(app: Ctx&, secret: const u8[:], sub: const u8[:], ttl_sec: i64) -> const u8[:] {
    let now = honk_unix_sec();
    let pstart = app.tmp.len;
    app.tmp.push('{');
    json::format_key(app.tmp, "sub");
    json::format_string(app.tmp, sub);
    app.tmp.push(',');
    json::format_key(app.tmp, "iat");
    json::format_int(app.tmp, now);
    app.tmp.push(',');
    json::format_key(app.tmp, "exp");
    json::format_int(app.tmp, now + ttl_sec);
    app.tmp.push('}');
    let payload = app.tmp[pstart..];
    var pay_copy: u8[>..] = [];
    pay_copy.append(payload);
    return jwt_sign(pay_copy[..], secret, app.tmp);
}

// Read a string claim from a verified JWT payload JSON slice (zero-DOM).
fn jwt_claim_str(app: Ctx&, payload_json: const u8[:], key: const u8[:]) -> const u8[:], bool {
    var r = json::reader(payload_json);
    var found = false;
    var val_len: i64 = 0;
    let start = app.tmp.len;
    json::each_member(r) { k =>
        if k == key && !found {
            let s = json::read_string(r, app.tmp);
            if app.tmp.len == start {
                app.tmp.append(s);
            }
            val_len = s.len;
            found = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) || !found { return "", false; }
    return app.tmp[start .. start + val_len], true;
}

// Read an integer claim from a verified JWT payload JSON slice (zero-DOM).
fn jwt_claim_int(_app: Ctx&, payload_json: const u8[:], key: const u8[:]) -> i64, bool {
    var r = json::reader(payload_json);
    var found = false;
    var out_v: i64 = 0;
    json::each_member(r) { k =>
        if k == key && !found {
            out_v = json::read_int(r);
            found = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) || !found { return 0, false; }
    return out_v, true;
}

// Scoped HS256 JWT route/group guard: verifies `Authorization: Bearer <jwt>`,
// populates `app.user` (from `"sub"`, if present) + `app.authed`, and runs
// `F(claims_json)` — else stages `401` and marks `app.handled = true`.
inline fn jwt<F>(app: Ctx&, secret: const u8[:]) {
    if app.handled { return; }
    let tok, bok = app.bearer_token();
    if !bok {
        if app.json_err_mode { app.json_error(401, "unauthorized"); }
        else { app.text(401, "Unauthorized"); }
        app.handled = true;
    } else {
        let claims, vok = jwt_verify(tok, secret, app.tmp);
        if !vok {
            if app.json_err_mode { app.json_error(401, "invalid or expired token"); }
            else { app.text(401, "Unauthorized"); }
            app.handled = true;
        } else {
            let sub, sok = app.jwt_claim_str(claims, "sub");
            if sok { app.user = sub; }
            app.authed = true;
            F(claims);
        }
    }
}

// Stage an HMAC-SHA256 signed cookie (`name=val.<b64url_mac>`), binding `name`
// into the MAC input so cookies cannot be swapped across names.
fn set_signed_cookie(app: Ctx&, name: const u8[:], val: const u8[:], secret: const u8[:],
                     opts: const u8[:] = "Path=/; HttpOnly; SameSite=Lax") {
    var msg: u8[>..] = [];
    msg.append(name);
    msg.push('=');
    msg.append(val);
    let mac = hmac_sha256(secret, msg[..]);

    let start = app.tmp.len;
    app.tmp.append(val);
    app.tmp.push('.');
    b64url_encode(mac[..], app.tmp);
    app.set_cookie(name, app.tmp[start..], opts);
}

// Read and verify an HMAC-SHA256 signed cookie in constant time.
fn signed_cookie(app: Ctx&, name: const u8[:], secret: const u8[:]) -> const u8[:], bool {
    let raw, ok = app.cookie(name);
    if !ok || raw.len == 0 { return "", false; }
    var dot = -1;
    var i = raw.len - 1;
    while i >= 0 {
        if raw[i] == '.' { dot = i; break; }
        i--;
    }
    if dot < 0 || dot + 1 >= raw.len { return "", false; }
    let val = raw[..dot];
    let sig = raw[dot + 1 ..];

    var msg: u8[>..] = [];
    msg.append(name);
    msg.push('=');
    msg.append(val);
    let mac = hmac_sha256(secret, msg[..]);

    var want_buf: u8[>..] = [];
    let want = b64url_encode(mac[..], want_buf);
    if !ct_eq(sig, want) { return "", false; }
    return val, true;
}

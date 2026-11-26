// honk_ws.goose -- opt-in RFC 6455 WebSockets over the shared epoll loop (`honk::`).
//
// Opt-in submodule (`import honk.src.honk_ws.honk_ws;`): pure-Goose FIPS 180-4
// SHA-1 + Base64 `Sec-WebSocket-Accept` handshake (`101 Switching Protocols`)
// plus per-message dispatch. Upgraded connections multiplex on the worker's
// epoll loop (frames in core turns, one message callback per turn) instead of
// pinning a worker: many idle sockets share one thread at flat RSS.
//
//   app.ws("/ws/:room") { msg, ws => ws.send(msg); };

namespace honk;

import std;
import json;
import src.honk_net.honk_net;
import src.honk_ctx.honk_ctx;
import src.honk_app.honk_app;

inline fn rotl32(x: u32, n: u32) -> u32 {
    return (x << n) | (x >> (32 - n));
}

// FIPS 180-4 SHA-1 digest (20 bytes, used by RFC 6455 §4.2.2 Sec-WebSocket-Accept).
fn sha1(msg: const u8[:]) -> u8[20] {
    var h0: u32 = 0x67452301;
    var h1: u32 = 0xefcdab89;
    var h2: u32 = 0x98badcfe;
    var h3: u32 = 0x10325476;
    var h4: u32 = 0xc3d2e1f0;

    let bit_len: u64 = (msg.len as! u64) * 8;
    let rem = (msg.len + 9) % 64;
    let total = msg.len + 9 + (if rem == 0 { 0 } else { 64 - rem });
    let nblocks = total / 64;

    var blk: u8[64] = [0; 64];
    var w: u32[80] = [0; 80];

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
        while i < 80 {
            let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = rotl32(x, 1);
            i++;
        }

        var a = h0;
        var b = h1;
        var c = h2;
        var d = h3;
        var e = h4;

        for t in 80 {
            var f: u32 = 0;
            var k: u32 = 0;
            if t < 20 {
                f = (b & c) | ((~b) & d);
                k = 0x5a827999;
            } else if t < 40 {
                f = b ^ c ^ d;
                k = 0x6ed9eba1;
            } else if t < 60 {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8f1bbcdc;
            } else {
                f = b ^ c ^ d;
                k = 0xca62c1d6;
            }
            let temp = rotl32(a, 5) + f + e + k + w[t];
            e = d;
            d = c;
            c = rotl32(b, 30);
            b = a;
            a = temp;
        }

        h0 += a;
        h1 += b;
        h2 += c;
        h3 += d;
        h4 += e;
    }

    var out: u8[20] = [0; 20];
    let words: u32[5] = [h0, h1, h2, h3, h4];
    for idx in 5 {
        let v = words[idx];
        let o = idx * 4;
        out[o] = (v >> 24) as! u8;
        out[o + 1] = ((v >> 16) & 0xff) as! u8;
        out[o + 2] = ((v >> 8) & 0xff) as! u8;
        out[o + 3] = (v & 0xff) as! u8;
    }
    return out;
}

// RFC 4648 §4 standard Base64 encode (`+`, `/`, `=` padding).
fn b64_encode(src: const u8[:], out: u8[>..]&) -> const u8[:] {
    let tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let start = out.len;
    var i: i64 = 0;
    while i + 3 <= src.len {
        let v: u32 = ((src[i] as! u32) << 16) | ((src[i + 1] as! u32) << 8) | src[i + 2];
        out.push(tbl[((v >> 18) & 63) as! i64]);
        out.push(tbl[((v >> 12) & 63) as! i64]);
        out.push(tbl[((v >> 6) & 63) as! i64]);
        out.push(tbl[(v & 63) as! i64]);
        i += 3;
    }
    let rem = src.len - i;
    if rem == 1 {
        let v: u32 = (src[i] as! u32) << 16;
        out.push(tbl[((v >> 18) & 63) as! i64]);
        out.push(tbl[((v >> 12) & 63) as! i64]);
        out.push('=');
        out.push('=');
    } else if rem == 2 {
        let v: u32 = ((src[i] as! u32) << 16) | ((src[i + 1] as! u32) << 8);
        out.push(tbl[((v >> 18) & 63) as! i64]);
        out.push(tbl[((v >> 12) & 63) as! i64]);
        out.push(tbl[((v >> 6) & 63) as! i64]);
        out.push('=');
    }
    return out[start..];
}

// Compute RFC 6455 §4.2.2 `Sec-WebSocket-Accept` from `Sec-WebSocket-Key`.
fn ws_accept_key(client_key: const u8[:], out: u8[>..]&) -> const u8[:] {
    var cat: u8[>..] = [];
    cat.append(client_key);
    cat.append("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    let dig = sha1(cat);
    return b64_encode(dig[..], out);
}

inline fn hdr_has_token_ci(hdr: const u8[:], want: const u8[:]) -> bool {
    if hdr.len < want.len { return false; }
    var i: i64 = 0;
    while i + want.len <= hdr.len {
        var ok = true;
        for k in want.len {
            if !eq_ci(hdr[i + k], want[k]) { ok = false; break; }
        }
        if ok {
            let left_ok = i == 0 || hdr[i - 1] == ' ' || hdr[i - 1] == '\t' || hdr[i - 1] == ',';
            let r = i + want.len;
            let right_ok = r == hdr.len || hdr[r] == ' ' || hdr[r] == '\t' || hdr[r] == ',';
            if left_ok && right_ok { return true; }
        }
        i++;
    }
    return false;
}

struct Ws {
    fd: i32,
    slot: i64,
    opcode: i64,
    closed: bool,
}

inline fn send(w: Ws&, text: const u8[:]) -> bool {
    if w.closed { return false; }
    if !honk::ws_send_frame(w.fd, 1, text) {
        w.closed = true;
        return false;
    }
    return true;
}

inline fn send_bytes(w: Ws&, data: const u8[:]) -> bool {
    if w.closed { return false; }
    if !honk::ws_send_frame(w.fd, 2, data) {
        w.closed = true;
        return false;
    }
    return true;
}

inline fn send_json<F>(w: Ws&) -> bool {
    var jbuf: u8[>..] = [];
    var jw = JWriter { out: jbuf, first: true };
    json_run(jw) { j => F(j); };
    return w.send(jbuf);
}

inline fn ping(w: Ws&, payload: const u8[:] = "") -> bool {
    if w.closed { return false; }
    let n = if payload.len <= 125 { payload.len } else { 125 };
    return honk::ws_send_frame(w.fd, 9, payload[..n]);
}

fn close(w: Ws&, code: i64 = 1000) {
    if !w.closed && w.fd >= 0 {
        honk::ws_close_fd(w.fd, w.slot, code);
    }
    w.closed = true;
}
// Strict UTF-8 validity for text messages (RFC 6455 §8.1): rejects
// overlong encodings, surrogate halves, and codepoints above U+10FFFF.
fn ws_utf8_valid(s: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < s.len {
        let b0 = s[i];
        if b0 < 0x80 { i++; continue; }
        var need: i64 = 0;
        var lo: u8 = 0x80;
        var hi: u8 = 0xbf;
        if b0 >= 0xc2 && b0 <= 0xdf { need = 1; }
        else if b0 >= 0xe0 && b0 <= 0xef {
            need = 2;
            if b0 == 0xe0 { lo = 0xa0; }
            else if b0 == 0xed { hi = 0x9f; }
        } else if b0 >= 0xf0 && b0 <= 0xf4 {
            need = 3;
            if b0 == 0xf0 { lo = 0x90; }
            else if b0 == 0xf4 { hi = 0x8f; }
        } else { return false; }
        if i + need >= s.len { return false; }
        let c1 = s[i + 1];
        if c1 < lo || c1 > hi { return false; }
        var j: i64 = 2;
        while j <= need {
            let c = s[i + j];
            if c < 0x80 || c > 0xbf { return false; }
            j++;
        }
        i += need + 1;
    }
    return true;
}

// Upgrade matching GETs (101 + slot claim) or dispatch message turns.
// Callback form: `app.ws("/ws/:room") { msg, ws => ws.send(msg); };`
inline fn ws<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
    if app.ws_msg {
        let mok = match_route(app, route);
        if !mok { return; }
        app.path_matched = true;
        app.handled = true;
        var w = Ws { fd: app.fd, slot: app.ws_slot, opcode: honk::ws_slot_opcode(app.ws_slot), closed: false };
        if w.opcode == 1 && !ws_utf8_valid(app.body) {
            w.close(1007);
            return;
        }
        F(app.body, w);
        return;
    }
    let ok = match_route(app, route);
    if ok { app.path_matched = true; }
    if app.method == "GET" && !app.head_only && ok {
        app.handled = true;
        let upg, uok = app.header("Upgrade");
        let conn_h, cok = app.header("Connection");
        let ver, vok = app.header("Sec-WebSocket-Version");
        let key, kok = app.header("Sec-WebSocket-Key");

        if !uok || !cok || !hdr_has_token_ci(upg, "websocket") || !hdr_has_token_ci(conn_h, "upgrade") || !kok || key.len == 0 {
            if app.json_err_mode { app.json_error(400, "bad websocket upgrade"); }
            else { app.text(400, "Bad Request"); }
        } else if !vok || ver != "13" {
            app.set_header("Sec-WebSocket-Version", "13");
            if app.json_err_mode { app.json_error(426, "upgrade required"); }
            else { app.text(426, "Upgrade Required"); }
        } else {
            let accept = ws_accept_key(key, app.tmp);
            app.status = 101;
            app.keep_alive = false;
            app.responded = true;
            if app.fd < 0 {
                app.set_header("Upgrade", "websocket");
                app.set_header("Connection", "Upgrade");
                app.set_header("Sec-WebSocket-Accept", accept);
            } else {
                emit_server_timing(app);
                let si = honk::ws_slot_alloc(app.fd);
                if si < 0 {
                    if app.json_err_mode { app.json_error(503, "too many websocket connections"); }
                    else { app.text(503, "Service Unavailable"); }
                    app.keep_alive = false;
                    return;
                }
                var hs: u8[>..] = [];
                hs.append("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
                hs.append(accept);
                hs.append("\r\nDate: ");
                hs.append(app.date);
                let n_ex = if app.n_extra <= 16 { app.n_extra } else { 16 };
                for i in n_ex {
                    hs.append("\r\n");
                    hs.append(app.extras[i].name);
                    hs.append(": ");
                    hs.append(app.extras[i].val);
                }
                hs.append("\r\n\r\n");
                app.sent = true;
                if honk_send(app.fd, hs) < 0 {
                    honk::ws_slot_free(si);
                    return;
                }
                var aux: u8[>..] = [];
                aux.append(app.base_path);
                aux.append(app.user);
                honk_ws_aux_set(app.fd, aux[..]);
                honk::ws_slot_aux_meta(si, app.base_path.len, app.user.len, app.authed);
                honk_ws_upgrade(app.fd, si as! i32);
                app.ws_upgraded_now = true;
            }
        }
    }
}

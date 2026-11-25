// honk_ws.goose -- opt-in RFC 6455 WebSocket handshake + frame reader/writer (`honk::`).
//
// Opt-in submodule (`import honk.src.honk_ws.honk_ws;`): pure-Goose FIPS 180-4
// SHA-1 + Base64 `Sec-WebSocket-Accept` handshake (`101 Switching Protocols`),
// masked client frame validation, automatic `Ping` -> `Pong`, fragmented message
// reassembly (<= 1 MiB), and zero-growth per-message data-stack resets.
//
//   app.ws("/ws/:room") { ws =>
//       ws.each_msg() { msg => ws.send(msg); };
//   };

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
    timeout_ms: i32,
    closed: bool,
    close_sent: bool,
}

inline fn set_timeout(ws: Ws&, timeout_ms: i32) {
    ws.timeout_ms = timeout_ms;
}

// Send an unmasked RFC 6455 server-to-client frame (`FIN = 1`).
fn send_frame(ws: Ws&, opcode: i64, payload: const u8[:]) -> bool {
    if ws.closed || ws.fd < 0 { return false; }
    var frame: u8[>..] = [];
    frame.push((0x80 | (opcode & 0x0f)) as! u8);
    let n = payload.len;
    if n < 126 {
        frame.push(n as! u8);
    } else if n <= 65535 {
        frame.push(126);
        frame.push(((n >> 8) & 0xff) as! u8);
        frame.push((n & 0xff) as! u8);
    } else {
        frame.push(127);
        for s in 8 {
            let sh = (7 - s) * 8;
            frame.push(((n >> sh) & 0xff) as! u8);
        }
    }
    frame.append(payload);
    if honk_ws_send_all(ws.fd, frame, ws.timeout_ms) < 0 {
        ws.closed = true;
        return false;
    }
    return true;
}

inline fn send(ws: Ws&, text: const u8[:]) -> bool {
    return ws.send_frame(1, text);
}

inline fn send_bytes(ws: Ws&, data: const u8[:]) -> bool {
    return ws.send_frame(2, data);
}

inline fn send_json<F>(ws: Ws&) -> bool {
    var jbuf: u8[>..] = [];
    var w = JWriter { out: jbuf, first: true };
    json_run(w) { j => F(j); };
    return ws.send_frame(1, jbuf);
}

inline fn ping(ws: Ws&, payload: const u8[:] = "") -> bool {
    let n = if payload.len <= 125 { payload.len } else { 125 };
    return ws.send_frame(9, payload[..n]);
}

fn close(ws: Ws&, code: i64 = 1000) {
    if !ws.close_sent && ws.fd >= 0 {
        var cbuf: u8[2] = [((code >> 8) & 0xff) as! u8, (code & 0xff) as! u8];
        ws.close_sent = true;
        ws.send_frame(8, cbuf[..]);
    }
    ws.closed = true;
}

// Read the next complete WebSocket data message into `msg_buf` (resetting `msg_buf` first).
// Automatically answers `Ping` with `Pong`, handles `Close`, and reassembles fragments (<= 1 MiB).
// Returns `(payload_slice, opcode, ok)`.
fn recv_into(ws: Ws&, msg_buf: u8[>..]&) -> const u8[:], i64, bool {
    honk_buf_reset(msg_buf);
    if ws.closed || ws.fd < 0 { return "", 0, false; }

    let max_msg: i64 = 1048576;
    var msg_opcode: i64 = 0;
    var in_frag = false;

    loop {
        var hdr: u8[>..] = [];
        if honk_ws_recv_exact(ws.fd, hdr, 2, ws.timeout_ms) != 2 {
            ws.closed = true;
            return "", 0, false;
        }
        let b0 = hdr[0];
        let b1 = hdr[1];
        let fin = (b0 & 0x80) != 0;
        let rsv = b0 & 0x70;
        let opcode: i64 = b0 & 0x0f;
        let masked = (b1 & 0x80) != 0;
        var plen: i64 = b1 & 0x7f;

        // RFC 6455 §5.1 / §5.2: RSV bits must be 0; client frames MUST be masked.
        if rsv != 0 || !masked {
            ws.close(1002);
            return "", 0, false;
        }

        let is_ctrl = (opcode & 0x08) != 0;
        if is_ctrl && (!fin || plen > 125) {
            ws.close(1002);
            return "", 0, false;
        }

        if plen == 126 {
            honk_buf_reset(hdr);
            if honk_ws_recv_exact(ws.fd, hdr, 2, ws.timeout_ms) != 2 {
                ws.closed = true;
                return "", 0, false;
            }
            plen = ((hdr[0] as! i64) << 8) | hdr[1];
        } else if plen == 127 {
            honk_buf_reset(hdr);
            if honk_ws_recv_exact(ws.fd, hdr, 8, ws.timeout_ms) != 8 {
                ws.closed = true;
                return "", 0, false;
            }
            if (hdr[0] & 0x80) != 0 {
                ws.close(1002);
                return "", 0, false;
            }
            var len64: u64 = 0;
            for k in 8 {
                len64 = (len64 << 8) | hdr[k];
            }
            if len64 > (max_msg as! u64) {
                ws.close(1009);
                return "", 0, false;
            }
            plen = len64 as! i64;
        }

        if plen > max_msg || (!is_ctrl && msg_buf.len + plen > max_msg) {
            ws.close(1009);
            return "", 0, false;
        }

        honk_buf_reset(hdr);
        if honk_ws_recv_exact(ws.fd, hdr, 4, ws.timeout_ms) != 4 {
            ws.closed = true;
            return "", 0, false;
        }
        let mask_be: i32 = (((hdr[0] as! u32) << 24)
                         | ((hdr[1] as! u32) << 16)
                         | ((hdr[2] as! u32) << 8)
                         | hdr[3]) as! i32;

        if is_ctrl {
            var ctrl: u8[>..] = [];
            if plen > 0 {
                if honk_ws_recv_exact(ws.fd, ctrl, plen as! i32, ws.timeout_ms) != (plen as! i32) {
                    ws.closed = true;
                    return "", 0, false;
                }
                honk_ws_unmask(ctrl, 0, plen, mask_be);
            }
            if opcode == 8 {
                // Close frame: echo close code (or 1000) and stop.
                let code: i64 = if ctrl.len >= 2 { ((ctrl[0] as! i64) << 8) | ctrl[1] } else { 1000 };
                ws.close(code);
                return "", 0, false;
            } else if opcode == 9 {
                // Ping -> automatic Pong with identical payload.
                ws.send_frame(10, ctrl);
            } else if opcode != 10 {
                ws.close(1002);
                return "", 0, false;
            }
            continue;
        }

        // Data frame (`1` text, `2` binary, `0` continuation)
        if !in_frag {
            if opcode != 1 && opcode != 2 {
                ws.close(1002);
                return "", 0, false;
            }
            msg_opcode = opcode;
            in_frag = !fin;
        } else {
            if opcode != 0 {
                ws.close(1002);
                return "", 0, false;
            }
            if fin { in_frag = false; }
        }

        let off = msg_buf.len;
        if plen > 0 {
            if honk_ws_recv_exact(ws.fd, msg_buf, plen as! i32, ws.timeout_ms) != (plen as! i32) {
                ws.closed = true;
                return "", 0, false;
            }
            honk_ws_unmask(msg_buf, off, plen, mask_be);
        }

        if fin {
            return msg_buf[..], msg_opcode, true;
        }
    }
}

// Loop over incoming WebSocket messages until peer close, timeout, or server stop.
inline fn each_msg<F>(ws: Ws&) {
    var msg_buf: u8[>..] = [];
    while !ws.closed {
        let msg, _op, ok = ws.recv_into(msg_buf);
        if !ok { break; }
        F(msg);
    }
}

inline fn ws_run<F>(ws: Ws&) {
    F(ws);
}

// Upgrade matching `GET` requests to RFC 6455 WebSocket (`101 Switching Protocols`).
inline fn ws<F>(app: Ctx&, route: const u8[:]) {
    if app.handled { return; }
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
                if honk_ws_send_all(app.fd, hs, 5000) == 0 {
                    var sock = Ws { fd: app.fd, timeout_ms: 30000, closed: false, close_sent: false };
                    ws_run(sock) { w => F(w); };
                    if !sock.close_sent && !sock.closed {
                        sock.close(1000);
                    }
                }
            }
        }
    }
}

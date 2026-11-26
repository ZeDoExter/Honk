// honk_serve.goose -- one-call server runner (`honk::` namespace).
//
// Apps declare a thin worker + main and put routes in blocks; ALL transport
// mechanics (listen, epoll loop, per-request 4-buffer scopes, default 404,
// central emit, pipelining, clean shutdown) live here as inline functions,
// so user dispatch monomorphizes straight into the worker loop with zero
// overhead (verified: no `_g` definitions for serve/request in generated C).
//
//   thread_fn worker(port: i32) {
//       honk::listen_or_abort(port);
//       honk::serve() { fd, date =>
//           honk::request(fd, date) { ctx =>
//               if ctx.method == "GET" && ctx.path == "/" {
//                   ctx.text(200, "Hello, World!");
//               }
//           };
//       };
//   }
//   fn main() {
//       let tid = thread_spawn(worker, 18080);
//       thread_wait(tid);
//   }

namespace honk;

import std;
import json;
import src.honk_net.honk_net;
import src.honk_ctx.honk_ctx;

extern fn honk_sendfile_data(fd: i32, file_fd: i32, offset: i64, count: i64) -> i32;

struct Config {
    port: i32,
    idle_ms: i32 = 30000,
    header_ms: i32 = 10000,
    worker_id: i32 = 0,
    cpu_id: i32 = -1,   // -1 = no pinning; else pin to this logical CPU
}

// Listen with default timeouts and no CPU pinning; aborts on failure.
fn listen_or_abort(port: i32) {
    honk_pin_thread_cpu(0, -1);
    honk_set_timeouts(30000, 10000);
    guard honk_worker_init(port) == 0 else { abort("honk_worker_init failed"); }
}

// Listen with full config (timeouts, worker id, CPU pin); aborts on failure.
fn listen_cfg_or_abort(cfg: Config&) {
    honk_pin_thread_cpu(cfg.worker_id, cfg.cpu_id);
    honk_set_timeouts(cfg.idle_ms, cfg.header_ms);
    guard honk_worker_init(cfg.port) == 0 else { abort("honk_worker_init failed"); }
}

// Event loop: feeds every ready fd to F(fd, date) until shutdown is
// requested (SIGINT, SIGTERM, or honk_request_stop), then drains queued
// outbound bytes and shuts the worker down cleanly for LSan.
inline fn serve<F>() {
    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];
    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 100);
        if nfds > 0 {
            assert(nfds <= 256);
            for i in nfds {
                let fd = ready_fds[i];
                F(fd, date_hdr);
            }
        }
        if honk_should_stop() != 0 {
            honk_worker_shutdown();
            break;
        }
    }
}

// --- non-blocking WebSocket turns (one worker multiplexes HTTP + WS) ---
//
// Upgraded connections leave HTTP: each EPOLLIN turn drains socket bytes
// (plus any stashed partial frame via partial_rx), runs complete frames,
// and re-stashes the tail. State splits two ways: tiny Goose-global slots
// (~48B × 1024, per-worker copies) plus C lazy partial/message/aux buffers
// (NULL when idle, freed on close). The C-side slot index is the source of
// truth: stale Goose slots (fd reuse after untracked close) revalidate
// against it. Pool: 1024 upgraded conns per worker; handshake fails 503 past it.

struct WsSlot {
    used: bool,
    fd: i32,
    opcode: i64,
    frag: bool,
    aux_path_len: i64,
    aux_user_len: i64,
    authed: bool,
}

var ws_slots: WsSlot[1024] = [WsSlot { used: false, fd: -1, opcode: 0, frag: false, aux_path_len: 0, aux_user_len: 0, authed: false }; 1024];

inline fn ws_slot_init(si: i64, fd: i32) {
    ws_slots[si].used = true;
    ws_slots[si].fd = fd;
    ws_slots[si].opcode = 0;
    ws_slots[si].frag = false;
    ws_slots[si].aux_path_len = 0;
    ws_slots[si].aux_user_len = 0;
    ws_slots[si].authed = false;
}

inline fn ws_slot_free(si: i64) {
    if si >= 0 && si < 1024 {
        ws_slots[si].used = false;
        ws_slots[si].fd = -1;
    }
}

fn ws_slot_alloc(fd: i32) -> i64 {
    for i in 1024 {
        if !ws_slots[i].used {
            ws_slot_init(i, fd);
            return i;
        }
    }
    for i in 1024 {
        if ws_slots[i].used && honk_conn_ws_slot(ws_slots[i].fd) != i {
            ws_slots[i].used = false;
            ws_slots[i].fd = -1;
        }
    }
    for i in 1024 {
        if !ws_slots[i].used {
            ws_slot_init(i, fd);
            return i;
        }
    }
    return -1;
}

// Revalidate C-claimed slot SI for FD (defensive: resets on drift).
inline fn ws_slot_check(si: i64, fd: i32) -> i64 {
    if si < 0 || si >= 1024 { return -1; }
    if ws_slots[si].used && ws_slots[si].fd == fd { return si; }
    ws_slot_init(si, fd);
    return si;
}

inline fn ws_slot_aux_meta(si: i64, path_len: i64, user_len: i64, authed: bool) {
    if si >= 0 && si < 1024 {
        ws_slots[si].aux_path_len = path_len;
        ws_slots[si].aux_user_len = user_len;
        ws_slots[si].authed = authed;
    }
}

inline fn ws_slot_opcode(si: i64) -> i64 {
    if si >= 0 && si < 1024 && ws_slots[si].used { return ws_slots[si].opcode; }
    return 0;
}

// Server-to-client frame via honk_send (EAGAIN-safe, EPOLLOUT resume).
fn ws_send_frame(fd: i32, opcode: i64, payload: const u8[:]) -> bool {
    if fd < 0 { return false; }
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
    return honk_send(fd, frame) >= 0;
}

fn ws_close_fd(fd: i32, si: i64, code: i64) {
    var cbuf: u8[2] = [((code >> 8) & 0xff) as! u8, (code & 0xff) as! u8];
    ws_send_frame(fd, 8, cbuf[..]);
    ws_slot_free(si);
    honk_close(fd);
}

inline fn ws_run<F>(ctx: Ctx&) {
    F(ctx);
}

// One message turn over an upgraded fd: drain, run frames, dispatch each
// complete message through F as a WSMSG ctx (concrete path re-matched).
inline fn ws_turn<F>(fd: i32, si: i64, date: const u8[:]) {
    if ws_slot_check(si, fd) < 0 { return; }
    var rx: u8[>..] = [];
    let n = honk_ws_poll(fd, rx);
    if n < 0 {
        ws_slot_free(si);
        return;
    }
    if n == 0 { return; }
    let input = rx[..];
    var cur: i64 = 0;
    while cur + 2 <= input.len {
        let b0 = input[cur];
        let b1 = input[cur + 1];
        let fin = (b0 & 0x80) != 0;
        let opcode: i64 = b0 & 0x0f;
        let masked = (b1 & 0x80) != 0;
        var plen: i64 = b1 & 0x7f;
        var hlen: i64 = 2;
        if !masked || (b0 & 0x70) != 0 {
            ws_slot_free(si);
            ws_close_fd(fd, si, 1002);
            return;
        }
        if plen == 126 {
            if cur + 4 > input.len { break; }
            plen = ((input[cur + 2] as! i64) << 8) | input[cur + 3];
            hlen = 4;
        } else if plen == 127 {
            if cur + 10 > input.len { break; }
            if (input[cur + 2] & 0x80) != 0 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1002);
                return;
            }
            var len64: u64 = 0;
            for k in 8 {
                len64 = (len64 << 8) | input[cur + 2 + k];
            }
            if len64 > 1048576 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1009);
                return;
            }
            plen = len64 as! i64;
            hlen = 10;
        }
        if cur + hlen + 4 + plen > input.len { break; }
        let m0 = input[cur + hlen];
        let m1 = input[cur + hlen + 1];
        let m2 = input[cur + hlen + 2];
        let m3 = input[cur + hlen + 3];
        let pstart = cur + hlen + 4;
        let is_ctrl = (opcode & 0x08) != 0;
        if is_ctrl {
            if !fin || plen > 125 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1002);
                return;
            }
            if opcode == 8 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1000);
                return;
            } else if opcode == 9 {
                var pong: u8[>..] = [];
                for k in plen {
                    let mb: u8 = if (k & 3) == 0 { m0 } else if (k & 3) == 1 { m1 } else if (k & 3) == 2 { m2 } else { m3 };
                    pong.push(input[pstart + k] ^ mb);
                }
                if !ws_send_frame(fd, 10, pong[..]) {
                    ws_slot_free(si);
                    return;
                }
            } else if opcode != 10 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1002);
                return;
            }
            cur = pstart + plen;
            continue;
        }
        if !ws_slots[si].frag {
            if opcode != 1 && opcode != 2 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1002);
                return;
            }
            ws_slots[si].opcode = opcode;
            ws_slots[si].frag = !fin;
        } else {
            if opcode != 0 {
                ws_slot_free(si);
                ws_close_fd(fd, si, 1002);
                return;
            }
            if fin { ws_slots[si].frag = false; }
        }
        var frag: u8[>..] = [];
        for k in plen {
            let mb: u8 = if (k & 3) == 0 { m0 } else if (k & 3) == 1 { m1 } else if (k & 3) == 2 { m2 } else { m3 };
            frag.push(input[pstart + k] ^ mb);
        }
        let ar = honk_ws_msg_append(fd, frag[..]);
        if ar == -2 {
            ws_slot_free(si);
            ws_close_fd(fd, si, 1009);
            return;
        }
        if ar < 0 {
            ws_slot_free(si);
            return;
        }
        cur = pstart + plen;
        if fin {
            ws_dispatch(fd, si, date) { c => F(c); };
            if honk_conn_ws_slot(fd) != si {
                return;
            }
        }
    }
    honk_ws_finish(fd, rx, cur as! i32);
}

// Build a WSMSG ctx (handshake path/user restored from aux) and run F.
inline fn ws_dispatch<F>(fd: i32, si: i64, date: const u8[:]) {
    var res: u8[>..] = [];
    var tmp: u8[>..] = [];
    var dom: json::Node[>..] = [];
    var dstr: u8[>..] = [];
    var mbuf: u8[>..] = [];
    if honk_ws_msg_take(fd, mbuf) < 0 {
        ws_slot_free(si);
        return;
    }
    let astart = tmp.len;
    if honk_ws_aux_get(fd, tmp) < 0 {
        ws_slot_free(si);
        return;
    }
    let aux = tmp[astart..];
    let plen = ws_slots[si].aux_path_len;
    let ulen = ws_slots[si].aux_user_len;
    if plen < 0 || ulen < 0 || plen + ulen > aux.len {
        ws_slot_free(si);
        honk_close(fd);
        return;
    }
    var ctx = make_ctx("WSMSG", aux[..plen], mbuf[..], "", false, fd, date,
                       res, tmp, dom, dstr);
    ctx.ws_msg = true;
    ctx.ws_slot = si;
    ctx.user = aux[plen..plen + ulen];
    ctx.authed = ws_slots[si].authed;
    ws_run(ctx) { c => F(c); };
}

// Runs one request against a ctx borrowed by reference (blocks bind struct
// *values* by copy, so the reference must cross through this & param).
// Stages 404 when the block staged nothing. Static responses (ctx.sent)
// skip emit here: the turn sends their headers + file bytes directly.
inline fn request_run<F>(ctx: Ctx&, tx_buf: u8[>..]&, date: const u8[:]) {
    F(ctx);
    if !ctx.responded {
        ctx.text(404, "Not Found");
    }
    if !ctx.sent {
        ctx.emit(tx_buf, date);
    }
}

// One epoll turn: recv(), then run + send every pipelined request in order.
// Each request gets a fresh scope (builders reset per iteration) and is
// sent immediately, which keeps static file bytes ordered behind their own
// headers under pipelining (wrk never pipelines, so batching bought nothing
// measurable; correctness first).
inline fn request<F>(fd: i32, date: const u8[:]) {
    let wsi = honk_conn_ws_slot(fd);
    if wsi >= 0 {
        ws_turn(fd, wsi, date) { c => F(c); };
        return;
    }
    var rx_buf: u8[>..] = [];
    let base_top = honk_debug_stack_base(rx_buf);
    let total = honk_conn_read(fd, rx_buf);
    if total <= 0 {
        assert(honk_debug_stack_top(rx_buf) == base_top);
        return;
    }

    var cursor: i32 = 0;
    var close_conn = false;

    while cursor < rx_buf.len {
        var req = RawReq { .. };
        let rem: const u8[:] = rx_buf[cursor..];
        let pret = honk_parse_req(rem, req);
        if pret == -2 {
            break;
        }
        if pret < 0 {
            var txe: u8[>..] = [];
            write_error_response(txe, pret, date);
            honk_send(fd, txe);
            close_conn = true;
            break;
        }
        {
            // Per-request scope: all builders reset at block exit.
            var res_buf: u8[>..] = [];
            var tmp_buf: u8[>..] = [];
            var dom_buf: json::Node[>..] = [];
            var dstr_buf: u8[>..] = [];
            var tx_buf: u8[>..] = [];
            let method = rem[req.method_off .. req.method_end];
            let full_path = rem[req.path_off .. req.path_end];
            let body = rem[req.body_off .. req.body_end];
            // Raw header block: bytes between the request line and body_off.
            let hb = req.body_off as! i64;
            var line_end = -1;
            var k: i64 = 0;
            while k + 1 < hb {
                if rem[k] == '\r' && rem[k + 1] == '\n' {
                    line_end = k;
                    break;
                }
                k++;
            }
            let hdrs = if line_end >= 0 { rem[line_end + 2 .. hb] } else { rem[hb..hb] };
            let ka = req.keep_alive != 0;
            var ctx = make_ctx(method, full_path, body, hdrs, ka, fd, date,
                               res_buf, tmp_buf, dom_buf, dstr_buf);
            request_run(ctx, tx_buf, date) { c => F(c); };
            if ctx.ws_upgraded_now {
                // Handshake claimed this turn: stash pipelined tail as WS bytes.
                honk_ws_finish(fd, rx_buf, cursor + req.consumed);
                cursor = rx_buf.len as! i32;
                break;
            }
            if ctx.sent {
                // Static sendfile responses stage resp_hdrs / resp_file_fd;
                // chunked stream / SSE handlers flush directly during F(c).
                if ctx.resp_hdrs.len > 0 {
                    honk_send(fd, ctx.resp_hdrs);
                }
                if ctx.resp_file_fd >= 0 {
                    honk_sendfile_data(fd, ctx.resp_file_fd, ctx.resp_file_off, ctx.resp_file_n);
                }
            } else if tx_buf.len > 0 {
                honk_send(fd, tx_buf);
            }
            cursor += req.consumed;
            if !ctx.keep_alive {
                close_conn = true;
                break;
            }
        }
    }

    honk_conn_finish(fd, rx_buf, cursor, if close_conn { 1 } else { 0 });
    assert(honk_debug_stack_top(rx_buf) == base_top);
}

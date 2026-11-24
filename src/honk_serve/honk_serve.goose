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
import honk_net;
import honk_ctx;

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
// requested (via honk_request_stop, e.g. a /__shutdown route), then shuts
// the worker down cleanly so the process can exit 0 for LSan.
inline fn serve<F>() {
    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];
    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 100);
        if nfds <= 0 { continue; }
        assert(nfds <= 256);
        for i in nfds {
            let fd = ready_fds[i];
            F(fd, date_hdr);
        }
        if honk_should_stop() != 0 {
            honk_worker_shutdown();
            break;
        }
    }
}

// Runs one request against a ctx borrowed by reference (blocks bind struct
// *values* by copy, so the reference must cross through this & param;
// see probe_reffwd). Stages 404 when the block staged nothing, then emits.
inline fn request_run<F>(ctx: Ctx&, tx_buf: u8[>..]&, date: const u8[:]) {
    F(ctx);
    if !ctx.responded {
        ctx.text(404, "Not Found");
    }
    ctx.emit(tx_buf, date);
}

// One epoll turn: recv(), parse + run every pipelined request through F,
// send(), stash tails. Per-request builders live in an explicit inner scope
// so every data-stack top resets on each iteration (same discipline as the
// hand-written turn this replaces).
inline fn request<F>(fd: i32, date: const u8[:]) {
    var rx_buf: u8[>..] = [];
    let base_top = honk_debug_stack_base(rx_buf);
    let total = honk_conn_read(fd, rx_buf);
    if total <= 0 {
        assert(honk_debug_stack_top(rx_buf) == base_top);
        return;
    }

    var tx_buf: u8[>..] = [];
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
            write_error_response(tx_buf, pret, date);
            close_conn = true;
            break;
        }
        {
            // Per-request scope: all four builders reset at block exit.
            var res_buf: u8[>..] = [];
            var tmp_buf: u8[>..] = [];
            var dom_buf: json::Node[>..] = [];
            var dstr_buf: u8[>..] = [];
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
            var ctx = make_ctx(method, full_path, body, hdrs, ka, fd,
                               res_buf, tmp_buf, dom_buf, dstr_buf);
            request_run(ctx, tx_buf, date) { c => F(c); };
            cursor += req.consumed;
            if !ctx.keep_alive {
                close_conn = true;
                break;
            }
        }
    }

    if tx_buf.len > 0 {
        honk_send(fd, tx_buf);
    }
    honk_conn_finish(fd, rx_buf, cursor, if close_conn { 1 } else { 0 });
    assert(honk_debug_stack_top(rx_buf) == base_top);
}

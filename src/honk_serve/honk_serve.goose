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

extern fn honk_sendfile_data(fd: i32, file_fd: i32, count: i64) -> i32;

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
            if ctx.sent {
                // Static sendfile responses stage resp_hdrs / resp_file_fd;
                // chunked stream / SSE handlers flush directly during F(c).
                if ctx.resp_hdrs.len > 0 {
                    honk_send(fd, ctx.resp_hdrs);
                }
                if ctx.resp_file_fd >= 0 {
                    honk_sendfile_data(fd, ctx.resp_file_fd, ctx.resp_file_n);
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

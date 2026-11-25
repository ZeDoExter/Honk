// honk_net.goose -- Honk HTTP/1.1 network layer in Goose over src/shim/honk_shim.c.

import std;
import os;

struct RawReq {
    method_off: i32,
    method_end: i32,
    path_off: i32,
    path_end: i32,
    body_off: i32,
    body_end: i32,
    consumed: i32,
    keep_alive: i32,
}

extern fn honk_set_timeouts(idle_timeout_ms: i32, header_timeout_ms: i32);
extern fn honk_worker_init(port: i32) -> i32;
extern fn honk_worker_shutdown();
extern fn honk_wait(out_fds: i32[256]&, out_date29: u8[29]&, timeout_ms: i32) -> i32;
extern fn honk_conn_read(fd: i32, rx_buf: u8[>..]&) -> i32;
extern fn honk_parse_req(buf: const u8[:], out: RawReq&) -> i32;
extern fn honk_send(fd: i32, data: const u8[:]) -> i32;
extern fn honk_conn_finish(fd: i32, rx_buf: u8[>..]&, consumed: i32, close_conn: i32);
extern fn honk_close(fd: i32);

extern fn honk_pin_thread_cpu(worker_id: i32, cpu_id: i32) -> i32;
extern fn honk_worker_id() -> i32;
extern fn honk_request_stop();
extern fn honk_should_stop() -> i32;
extern fn honk_fork_workers(n: i32) -> i32;
extern fn honk_fork_env() -> i32;
extern fn honk_fork_join();
extern fn honk_now_ns() -> i64;
extern fn honk_unix_sec() -> i64;
extern fn honk_log_line(data: const u8[:]);
extern fn honk_conn_ip(fd: i32, out: u8[>..]&) -> i64;
extern fn honk_rate_allow(key_hash: i64, max_reqs: i32, window_ms: i32) -> i32;
extern fn honk_rate_reset();
extern fn honk_buf_reset(buf: u8[>..]&);
extern fn honk_ws_recv_exact(fd: i32, out: u8[>..]&, count: i32, timeout_ms: i32) -> i32;
extern fn honk_ws_unmask(out: u8[>..]&, offset: i64, len: i64, mask_be: i32);
extern fn honk_ws_send_all(fd: i32, data: const u8[:], timeout_ms: i32) -> i32;
extern fn honk_debug_stack_top(r: u8[>..]&) -> i64;
extern fn honk_debug_stack_base(r: u8[>..]&) -> i64;
extern fn honk_active_conns() -> i32;
extern fn honk_accepted_total() -> i64;
extern fn honk_rejected_conns() -> i64;
extern fn honk_timed_out_conns() -> i64;
extern fn honk_tx_queued_count() -> i64;
extern fn honk_shrink_sndbuf(fd: i32);

inline fn write_response(out: u8[>..]&, status: i64, status_text: const u8[:],
                         content_type: const u8[:], body: const u8[:],
                         date_hdr: const u8[:], keep_alive: bool) {
    out.append("HTTP/1.1 ");
    format(out, status);
    out.push(' ');
    out.append(status_text);
    out.append("\r\nContent-Type: ");
    out.append(content_type);
    out.append("\r\nDate: ");
    out.append(date_hdr);
    if !keep_alive {
        out.append("\r\nConnection: close");
    }
    out.append("\r\nContent-Length: ");
    format(out, body.len);
    out.append("\r\n\r\n");
    out.append(body);
}

inline fn write_error_response(out: u8[>..]&, err_code: i32, date_hdr: const u8[:]) {
    if err_code == -431 {
        write_response(out, 431, "Request Header Fields Too Large", "text/plain",
                       "Request Header Fields Too Large", date_hdr, false);
    } else if err_code == -413 {
        write_response(out, 413, "Payload Too Large", "text/plain",
                       "Payload Too Large", date_hdr, false);
    } else if err_code == -501 {
        write_response(out, 501, "Not Implemented", "text/plain",
                       "Not Implemented", date_hdr, false);
    } else {
        write_response(out, 400, "Bad Request", "text/plain",
                       "Bad Request", date_hdr, false);
    }
}

inline fn handle_minimal_request(fd: i32, method: const u8[:], path: const u8[:], body: const u8[:],
                                date_hdr: const u8[:], keep_alive: bool,
                                tx_buf: u8[>..]&) {
    if method == "GET" && (path == "/" || path == "/plaintext") {
        write_response(tx_buf, 200, "OK", "text/plain", "Hello, World!", date_hdr, keep_alive);
    } else if method == "POST" && path == "/echo" {
        write_response(tx_buf, 200, "OK", "text/plain", body, date_hdr, keep_alive);
    } else if method == "GET" && path == "/large" {
        // Shrink SO_SNDBUF on this socket so pipelined 16 KiB responses exercise EAGAIN + EPOLLOUT
        honk_shrink_sndbuf(fd);
        var payload: u8[>..] = [];
        for _ in 1024 {
            payload.append("0123456789ABCDEF");
        }
        write_response(tx_buf, 200, "OK", "text/plain", payload, date_hdr, keep_alive);
    } else if method == "GET" && path == "/stats" {
        var st: u8[>..] = [];
        st.append("worker=");
        format(st, honk_worker_id());
        st.append(" active=");
        format(st, honk_active_conns());
        st.append(" accepted=");
        format(st, honk_accepted_total());
        st.append(" rejected=");
        format(st, honk_rejected_conns());
        st.append(" timed_out=");
        format(st, honk_timed_out_conns());
        st.append(" tx_queued=");
        format(st, honk_tx_queued_count());
        write_response(tx_buf, 200, "OK", "text/plain", st, date_hdr, keep_alive);
    } else if method == "POST" && path == "/__shutdown" {
        honk_request_stop();
        write_response(tx_buf, 200, "OK", "text/plain", "shutting down", date_hdr, false);
    } else {
        write_response(tx_buf, 404, "Not Found", "text/plain", "Not Found", date_hdr, keep_alive);
    }
}

// Processes a single ready fd on the worker's data stack.
// Returns the data-stack top address of rx_buf immediately after turn completion
// (equal to the entry baseline).
inline fn process_ready_fd(fd: i32, date_hdr: const u8[:]) -> i64 {
    var rx_buf: u8[>..] = [];
    let base_top = honk_debug_stack_base(rx_buf);
    let total = honk_conn_read(fd, rx_buf);
    if total <= 0 {
        assert(honk_debug_stack_top(rx_buf) == base_top);
        return honk_debug_stack_top(rx_buf);
    }

    var tx_buf: u8[>..] = [];
    var cursor: i32 = 0;
    var close_conn = false;

    while cursor < rx_buf.len {
        var req = RawReq { .. };
        let rem_slice: const u8[:] = rx_buf[cursor..];
        let pret = honk_parse_req(rem_slice, req);
        if pret == -2 {
            break;
        }
        if pret < 0 {
            write_error_response(tx_buf, pret, date_hdr);
            close_conn = true;
            break;
        }
        let method = rem_slice[req.method_off .. req.method_end];
        let path = rem_slice[req.path_off .. req.path_end];
        let body = rem_slice[req.body_off .. req.body_end];
        let ka = req.keep_alive != 0;
        handle_minimal_request(fd, method, path, body, date_hdr, ka, tx_buf);
        cursor += req.consumed;
        if !ka {
            close_conn = true;
            break;
        }
    }

    if tx_buf.len > 0 {
        honk_send(fd, tx_buf);
    }
    honk_conn_finish(fd, rx_buf, cursor, if close_conn { 1 } else { 0 });
    assert(honk_debug_stack_top(rx_buf) == base_top);
    return honk_debug_stack_top(rx_buf);
}

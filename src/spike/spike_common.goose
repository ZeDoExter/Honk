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

struct ConnBuf {
    fd: i32,
    rx: u8[..16384],
}

extern fn honk_worker_init(port: i32) -> i32;
extern fn honk_wait(out_fds: i32[256]&, out_date29: u8[29]&, timeout_ms: i32) -> i32;
extern fn honk_d1_read(fd: i32, cb: ConnBuf&) -> i32;
extern fn honk_d2_read(fd: i32, rx_buf: u8[>..]&) -> i32;
extern fn honk_d2_consume(fd: i32, consumed: i32, close_conn: i32);
extern fn honk_d3_read(fd: i32, rx_buf: u8[>..]&) -> i32;
extern fn honk_d3_StashTail(fd: i32, unparsed_tail: const u8[:], close_conn: i32);
extern fn honk_parse_req(buf: const u8[:], out: RawReq&) -> i32;
extern fn honk_send(fd: i32, data: const u8[:]) -> i32;
extern fn honk_close(fd: i32);

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

inline fn handle_request(method: const u8[:], path: const u8[:],
                         date_hdr: const u8[:], keep_alive: bool,
                         tx_buf: u8[>..]&) {
    if method == "GET" && (path == "/" || path == "/plaintext") {
        write_response(tx_buf, 200, "OK", "text/plain", "Hello, World!", date_hdr, keep_alive);
    } else {
        write_response(tx_buf, 404, "Not Found", "text/plain", "Not Found", date_hdr, keep_alive);
    }
}

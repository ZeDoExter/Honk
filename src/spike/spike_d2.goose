// Step 1a Spike — Candidate (ii): Per-connection buffer on the C side (__thread),
// copied into a Goose per-iteration scope (rx_buf: u8[>..]) once data arrives.

import std;
import os;
import .spike_common;

thread_fn worker_d2(port: i32) {
    guard honk_worker_init(port) == 0 else { abort("honk_worker_init failed"); }
    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];

    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 500);
        if nfds <= 0 { continue; }
        assert(nfds <= 256);

        for i in nfds {
            let fd = ready_fds[i];
            var rx_buf: u8[>..] = [];
            let total = honk_d2_read(fd, rx_buf);
            if total <= 0 { continue; }

            var tx_buf: u8[>..] = [];
            var cursor: i32 = 0;
            var close_conn = false;

            while cursor < rx_buf.len {
                var req = RawReq { .. };
                let rem_slice: const u8[:] = rx_buf[cursor..];
                let pret = honk_parse_req(rem_slice, req);
                if pret == -2 { break; }
                if pret < 0 {
                    close_conn = true;
                    break;
                }
                let method = rem_slice[req.method_off .. req.method_end];
                let path = rem_slice[req.path_off .. req.path_end];
                let ka = req.keep_alive != 0;
                handle_request(method, path, date_hdr, ka, tx_buf);
                cursor += req.consumed;
                if !ka {
                    close_conn = true;
                    break;
                }
            }

            if tx_buf.len > 0 {
                honk_send(fd, tx_buf);
            }
            honk_d2_consume(fd, cursor, if close_conn { 1 } else { 0 });
        }
    }
}

fn main() {
    var port: i32 = 18082;
    let a = args();
    if a.len > 1 {
        let p, ok = parse_int(a[1]);
        if ok { port = p as! i32; }
    }
    print("Goose spike D2 (C per-conn buffer -> Goose scope copy) listening on port ", port);
    flush_stdout();
    let tid = thread_spawn(worker_d2, port);
    thread_wait(tid);
}

// Step 1a Spike — Candidate (i): Fixed-capacity per-connection buffer u8[..16384]
// inside a struct held in a Goose slot_pool<ConnBuf>.

import std;
import os;
import slot_pool;
import .spike_common;

thread_fn worker_d1(port: i32) {
    guard honk_worker_init(port) == 0 else { abort("honk_worker_init failed"); }
    var pool = slot_pool<ConnBuf> {};
    // Pre-populate slots for fds 0..1024 in the worker-local slot_pool
    for i in 1024 {
        pool.alloc_with() { ConnBuf { fd: -1, rx: [] } };
    }

    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];

    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 500);
        if nfds <= 0 { continue; }
        assert(nfds <= 256);

        for i in nfds {
            let fd = ready_fds[i];
            guard fd >= 0 && fd < pool.items.len else { continue; }
            var cb .= pool.items[fd];
            let total = honk_d1_read(fd, cb);
            if total <= 0 { continue; }

            var tx_buf: u8[>..] = [];
            var cursor: i32 = 0;
            var close_conn = false;

            while cursor < cb.rx.len {
                var req = RawReq { .. };
                let rem_slice: const u8[:] = cb.rx[cursor..];
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

            if close_conn {
                cb.rx.clear();
                honk_close(fd);
            } else if cursor == cb.rx.len {
                cb.rx.clear();
            } else if cursor > 0 {
                let rem = cb.rx.len - cursor;
                cb.rx[0..rem].move_from(cb.rx[cursor..]);
                cb.rx.resize(rem);
            }
        }
    }
}

fn main() {
    var port: i32 = 18081;
    let a = args();
    if a.len > 1 {
        let p, ok = parse_int(a[1]);
        if ok { port = p as! i32; }
    }
    print("Goose spike D1 (slot_pool<ConnBuf> u8[..16384]) listening on port ", port);
    flush_stdout();
    let tid = thread_spawn(worker_d1, port);
    thread_wait(tid);
}

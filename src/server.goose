// server.goose -- Honk framework server (+ cross-framework bench mode).
// Usage: ./server [port] [idle_timeout_ms] [header_timeout_ms] [num_workers] [bench_mode]
// Same transport/worker model as Phase 1; requests dispatch through the
// honk_router framework (Ctx + middleware + routes + JSON).

import std;
import os;
import honk_net from "./honk_net";
import honk_router from "./honk_router";
import honk_ctx from "./honk_ctx";
import honk_json from "./honk_json";

struct WorkerCfg2 {
    port: i32,
    idle_timeout_ms: i32,
    header_timeout_ms: i32,
    worker_id: i32,
    cpu_id: i32,
    bench: i32,
}

thread_fn worker_phase2(cfg: WorkerCfg2) {
    HONK_BENCH_MODE = cfg.bench != 0;
    honk_pin_thread_cpu(cfg.worker_id, cfg.cpu_id);
    honk_set_timeouts(cfg.idle_timeout_ms, cfg.header_timeout_ms);
    guard honk_worker_init(cfg.port) == 0 else { abort("honk_worker_init failed"); }

    var ready_fds: i32[256] = [0; 256];
    var date_hdr: u8[29] = [0; 29];

    loop {
        let nfds = honk_wait(ready_fds, date_hdr, 100);
        if nfds <= 0 { continue; }
        assert(nfds <= 256);

        for i in nfds {
            let fd = ready_fds[i];
            process_ready_fd2(fd, date_hdr);
        }
        if honk_should_stop() != 0 {
            honk_worker_shutdown();
            break;
        }
    }
}

fn main() {
    var port: i32 = 18080;
    var idle_timeout_ms: i32 = 30000;
    var header_timeout_ms: i32 = 10000;
    var num_workers: i32 = 1;
    var bench: i32 = 0;

    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    if a.len > 2 {
        let v, ok = parse_int(a[2]);
        if ok { idle_timeout_ms = v as! i32; }
    }
    if a.len > 3 {
        let v, ok = parse_int(a[3]);
        if ok { header_timeout_ms = v as! i32; }
    }
    if a.len > 4 {
        let v, ok = parse_int(a[4]);
        if ok { num_workers = v as! i32; }
    }
    if a.len > 5 {
        let v, ok = parse_int(a[5]);
        if ok { bench = v as! i32; }
    }
    assert(num_workers >= 1 && num_workers <= 4);

    print("Honk server listening on port ", port,
          " (workers=", num_workers,
          ", idle_timeout_ms=", idle_timeout_ms,
          ", header_timeout_ms=", header_timeout_ms,
          ", bench=", bench, ")");
    flush_stdout();
    var tids: i64[..4] = [];
    for w in num_workers {
        // Physical core mapping on 4C/8T WSL2 (lscpu -e):
        // Core 0 -> CPU 0, Core 1 -> CPU 2, Core 2 -> CPU 4, Core 3 -> CPU 6
        let cpu_id: i32 = w * 2;
        let cfg = WorkerCfg2 {
            port: port,
            idle_timeout_ms: idle_timeout_ms,
            header_timeout_ms: header_timeout_ms,
            worker_id: w,
            cpu_id: cpu_id,
            bench: bench,
        };
        tids.push(thread_spawn(worker_phase2, cfg));
    }

    for tid in tids {
        thread_wait(tid);
    }
}

// server.goose -- Honk framework demo server (+ cross-framework bench mode).
// Usage: ./server [port] [idle_timeout_ms] [header_timeout_ms] [num_workers] [bench_mode]
// bench_mode=1 enables HONK_BENCH_MODE: workload-exact routes on standard
// paths with decoration middleware off. All transport mechanics live in
// honk_serve; this file only declares the worker, spawns it, and routes.

import std;
import os;
import honk from ".";
import honk.honk_json.honk_json;
import honk.honk_router.honk_router;

struct WorkerCfg {
    port: i32,
    idle_timeout_ms: i32,
    header_timeout_ms: i32,
    worker_id: i32,
    cpu_id: i32,
    bench: i32,
}

thread_fn worker(cfg: WorkerCfg) {
    honk::HONK_BENCH_MODE = cfg.bench != 0;
    var scfg = honk::Config {
        port: cfg.port,
        idle_ms: cfg.idle_timeout_ms,
        header_ms: cfg.header_timeout_ms,
        worker_id: cfg.worker_id,
        cpu_id: cfg.cpu_id,
    };
    honk::listen_cfg_or_abort(scfg);
    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            honk::dispatch(ctx);
        };
    };
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
        let cfg = WorkerCfg {
            port: port,
            idle_timeout_ms: idle_timeout_ms,
            header_timeout_ms: header_timeout_ms,
            worker_id: w,
            cpu_id: cpu_id,
            bench: bench,
        };
        tids.push(thread_spawn(worker, cfg));
    }

    for tid in tids {
        thread_wait(tid);
    }
}

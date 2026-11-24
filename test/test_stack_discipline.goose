// test_stack_discipline.goose -- Requirement E:
// Runs every C shim code path that touches gs_rref / data-stack top
// (success, EAGAIN [empty + with stashed partial_rx], recv()==0, recv()==-1 / peer reset,
// 431 header too large, 413 body too large, 501 chunked, 400 malformed, timeout)
// 100,000 times EACH (900,000 total turns) and asserts the Goose data-stack top
// equals the exact baseline on every single iteration and afterwards.

import std;
import os;
import honk_net from "../src";

extern fn test_helper_init(port: i32) -> i32;
extern fn test_helper_cleanup();
extern fn test_get_persistent_cfd() -> i32;
extern fn test_set_persistent_partial_rx();
extern fn test_write_valid_req();
extern fn test_drain_client_rx();
extern fn test_prep_eof_fd() -> i32;
extern fn test_prep_err_fd(simulate_reset: i32) -> i32;
extern fn test_prep_431_fd() -> i32;
extern fn test_prep_413_fd() -> i32;
extern fn test_prep_501_fd() -> i32;
extern fn test_prep_400_fd() -> i32;
extern fn test_prep_timeout_fd() -> i32;
extern fn test_expire_and_sweep_fd(cfd: i32);

inline fn current_rx_stack_top() -> i64 {
    var probe: u8[>..] = [];
    return honk_debug_stack_top(probe);
}

fn main() {
    let iters: i64 = 100_000;
    guard test_helper_init(18999) == 0 else { abort("test_helper_init failed"); }
    let date_hdr: const u8[:] = "Tue, 24 Nov 2026 12:00:00 GMT";

    let baseline = current_rx_stack_top();
    print("Baseline data-stack top: ", baseline);

    // 1. Success path (100,000 iterations)
    let p_cfd = test_get_persistent_cfd();
    for i in iters {
        test_write_valid_req();
        let top = process_ready_fd(p_cfd, date_hdr);
        assert(top == baseline);
        if (i & 15) == 15 {
            test_drain_client_rx();
        }
    }
    test_drain_client_rx();
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 1: success (200 OK) x ", iters, " -> stack top == baseline (", baseline, ")");

    // 2. EAGAIN path (50,000 empty + 50,000 with stashed partial_rx prepended then rolled back = 100,000 iterations)
    for _ in 50_000 {
        let top = process_ready_fd(p_cfd, date_hdr);
        assert(top == baseline);
    }
    test_set_persistent_partial_rx();
    for _ in 50_000 {
        let top = process_ready_fd(p_cfd, date_hdr);
        assert(top == baseline);
    }
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 2: EAGAIN (50k empty + 50k partial_rx rollback) x ", iters, " -> stack top == baseline");

    // Close persistent fd before single-turn close paths
    honk_close(p_cfd);
    assert(honk_active_conns() == 0);

    // 3. recv() == 0 (EOF / peer close with partial_rx prepended then rolled back, 100,000 iterations)
    for _ in iters {
        let cfd = test_prep_eof_fd();
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
    }
    assert(honk_active_conns() == 0);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 3: recv() == 0 (EOF) x ", iters, " -> stack top == baseline");

    // 4. recv() == -1 / peer reset (fatal error with partial_rx prepended then rolled back, 100,000 iterations)
    for _ in iters {
        let cfd = test_prep_err_fd(1);
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
    }
    assert(honk_active_conns() == 0);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 4: recv() == -1 / peer reset x ", iters, " -> stack top == baseline");

    // 5. 431 Request Header Fields Too Large (100,000 iterations)
    for i in iters {
        let cfd = test_prep_431_fd();
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
        if (i & 7) == 7 {
            test_drain_client_rx();
        }
    }
    test_drain_client_rx();
    assert(honk_active_conns() == 0);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 5: 431 Request Header Fields Too Large x ", iters, " -> stack top == baseline");

    // 6. 413 Payload Too Large (100,000 iterations)
    for i in iters {
        let cfd = test_prep_413_fd();
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
        if (i & 15) == 15 {
            test_drain_client_rx();
        }
    }
    test_drain_client_rx();
    assert(honk_active_conns() == 0);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 6: 413 Payload Too Large x ", iters, " -> stack top == baseline");

    // 7. 501 Not Implemented (Transfer-Encoding: chunked, 100,000 iterations)
    for i in iters {
        let cfd = test_prep_501_fd();
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
        if (i & 15) == 15 {
            test_drain_client_rx();
        }
    }
    test_drain_client_rx();
    assert(honk_active_conns() == 0);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 7: 501 Not Implemented (chunked) x ", iters, " -> stack top == baseline");

    // 8. 400 Bad Request (malformed HTTP, 100,000 iterations)
    for i in iters {
        let cfd = test_prep_400_fd();
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
        if (i & 15) == 15 {
            test_drain_client_rx();
        }
    }
    test_drain_client_rx();
    assert(honk_active_conns() == 0);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 8: 400 Bad Request x ", iters, " -> stack top == baseline");

    // 9. Timeout path (read incomplete header into rx_buf -> stash in partial_rx -> timeout sweep, 100,000 iterations)
    for _ in iters {
        let cfd = test_prep_timeout_fd();
        assert(cfd >= 0);
        let top = process_ready_fd(cfd, date_hdr);
        assert(top == baseline);
        test_expire_and_sweep_fd(cfd);
    }
    assert(honk_active_conns() == 0);
    assert(honk_timed_out_conns() == iters);
    assert(current_rx_stack_top() == baseline);
    print("[PASS] Path 9: Partial read + timeout sweep x ", iters, " -> stack top == baseline");

    test_helper_cleanup();
    honk_worker_shutdown();
    print("ALL 9 STACK-DISCIPLINE PATHS (900,000 TOTAL ITERATIONS) PASSED!");
}

import std;

struct Span { off: i32, len: i32 }

extern fn shim_fill_direct(out: u8[>..]&, out_span: Span&) -> i32;

thread_fn worker(id: i32) {
    for round in 3 {
        var rx_buf: u8[>..] = [];
        var sp = Span { off: 0, len: 0 };
        let n = shim_fill_direct(rx_buf, sp);
        let view: const u8[:] = rx_buf[sp.off .. sp.off + sp.len];
        assert(n == 23 && rx_buf.len == 23 && view == "hello from gs_rref");
        if round == 2 {
            print("worker ", id, " round ", round, " ok: '", view, "' len=", rx_buf.len);
        }
    }
}

fn main() {
    let tid = thread_spawn(worker, 1);
    assert(thread_wait(tid));
}

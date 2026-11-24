# Architectural & Engineering Decisions (`docs/DECISIONS.md`)

## D-001: Primary Target Environment — WSL2 Linux (Ubuntu 24.04, GCC 13.3.0)
- **Context**: The host machine runs Windows 10/11 with WSL2 (Ubuntu 24.04.4 LTS, Linux kernel `6.6.87.2-microsoft-standard-WSL2`). Phases 1–3 require Linux `epoll`, `SO_REUSEPORT` kernel load-balancing across `thread_fn` workers, `taskset` CPU pinning, and `wrk`.
- **Decision**: Build and run the Honk server, C epoll shim, test suite, and Phase 3 benchmarks (Honk, Elysia/Bun, bare C epoll reference) natively inside WSL2 Linux using the Linux Goose compiler (`goose_repo/build-linux/goose` + GCC 13.3.0). We also built `goose_repo/build/Release/goose.exe` (MSVC 19.44) for Windows host checks.
- **Why**: Keeps all three benchmarked servers (Honk, Elysia/Bun, bare C) on the exact same Linux kernel, loopback stack, and load generator (`wrk`) with authentic `epoll` and `SO_REUSEPORT`.

## D-002: Use Standard Library `json` (`stdlib/json.goose`) Instead of `samples/18_json.goose`
- **Context**: Goose ships both an educational JSON sample (`samples/18_json.goose`) and a production standard library module (`stdlib/json.goose`).
- **Decision**: Use `import json;` from the standard library (`stdlib/json.goose`).
- **Why**:
  1. `samples/18_json.goose` uses a global `var pool: Node[>..]` and copies all keys/strings into `u8[varint]`.
  2. `stdlib/json.goose` uses caller-owned per-request data-stack buffers (`doc: Node[>..]&`, `decoded: u8[>..]&`, or `scratch: u8[>..]&`), keeps unescaped strings/keys as zero-copy `const u8[:]` slices into the HTTP request buffer, provides a zero-DOM typed streaming reader (`json::Reader`), and formats numbers in-place with an inline Ryu/SWAR implementation (`json::format_*`).

## D-003: Zero-Copy Data-Stack Socket Reads + Offset-Span FFI Boundary
- **Context**: Goose's `extern fn` rules (`goose_spec.md` §7.10) forbid structs containing slices (`u8[:]`) or references from crossing the C boundary, and forbid creating Goose slices directly from C-owned pointers without copying (`stdlib/ffi.goose`).
- **Decision**:
  1. Have C `recv()` read socket bytes directly into a per-turn Goose data-stack builder (`var rx_buf: u8[>..] = [];` passed as `u8[>..]&` / `gs_rref` to C), advancing `rx_buf.stk->top` and `rx_buf.hdr->len`.
  2. Have the C `picohttpparser` shim return a flat fixed-size `RawRequest` struct containing 32-bit `(off, len)` integer spans relative to `rx_buf`.
  3. Reconstruct zero-copy, lifetime-checked `const u8[:]` slices inside Goose by slicing `rx_buf[off .. off + len]`.
- **Why**: Satisfies Goose's strict FFI type rules while achieving true zero-copy request parsing, per-request data-stack deallocation (one pointer store on scope exit), and near-zero idle memory per keep-alive connection.

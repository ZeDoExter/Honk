// honk_sqlite.goose -- opt-in SQLite module (WAL + prepared statements).
//
// One sqlite3* handle per worker thread (NOMUTEX, zero cross-thread
// contention). All values bind via prepared statements (no SQL injection by
// construction). Column text appends once into a caller-owned builder — a
// single copy into request scope, zero heap Strings.
// Linkage is opt-in: only apps whose .build lists honk_sqlite_shim.c and
// -lsqlite3 pay for it (verified: non-SQLite binaries show no libsqlite3
// in ldd and keep their footprint).
//
// Shutdown order per worker: finalize every Stmt -> db_close ->
// (after ALL workers joined, main thread) db_shutdown() for LSan-clean exit.

import std;

extern fn hsql_open(path: const u8[:], flags: i32) -> u64;
extern fn hsql_close(db: u64) -> i32;
extern fn hsql_shutdown() -> i32;
extern fn hsql_exec(db: u64, sql: const u8[:]) -> i32;
extern fn hsql_prepare(db: u64, sql: const u8[:]) -> u64;
extern fn hsql_finalize(st: u64) -> i32;
extern fn hsql_step(st: u64) -> i32;
extern fn hsql_reset(st: u64) -> i32;
extern fn hsql_clear_bindings(st: u64) -> i32;
extern fn hsql_bind_int(st: u64, idx: i32, v: i64) -> i32;
extern fn hsql_bind_float(st: u64, idx: i32, v: f64) -> i32;
extern fn hsql_bind_text(st: u64, idx: i32, v: const u8[:], is_transient: i32) -> i32;
extern fn hsql_bind_null(st: u64, idx: i32) -> i32;
extern fn hsql_col_int(st: u64, idx: i32) -> i64;
extern fn hsql_col_float(st: u64, idx: i32) -> f64;
extern fn hsql_col_is_null(st: u64, idx: i32) -> i32;
extern fn hsql_col_bytes(st: u64, idx: i32) -> i64;
extern fn hsql_col_text(st: u64, idx: i32, out: u8[>..]&) -> i64;
extern fn hsql_last_id(db: u64) -> i64;
extern fn hsql_changes(db: u64) -> i64;
extern fn hsql_errcode(db: u64) -> i32;
extern fn hsql_errmsg(db: u64, out: u8[>..]&) -> i64;

// sqlite3_step() outcomes and open flags (mirrors sqlite3.h).
let ROW: i32 = 100;
let DONE: i32 = 101;
let OPEN_READWRITE: i32 = 2;
let OPEN_CREATE: i32 = 4;
let OPEN_NOMUTEX: i32 = 32768;

struct Db { h: u64 }
struct Stmt { h: u64 }

fn db_is_open(db: Db&) -> bool { db.h != 0 }
fn stmt_is_ready(st: Stmt&) -> bool { st.h != 0 }
// Open (or create) a database file. Call once per worker thread.
fn db_open(path: const u8[:]) -> Db, bool {
    let h = hsql_open(path, OPEN_READWRITE | OPEN_CREATE | OPEN_NOMUTEX);
    if h == 0 { return Db { h: 0 }, false; }
    return Db { h: h }, true;
}

// Standard Honk pragmas: busy wait FIRST (so concurrent workers retry
// instead of failing WAL setup/DDL), then WAL readers/writers, safe sync.
fn db_enable_wal(db: Db&) -> bool {
    if hsql_exec(db.h, "PRAGMA busy_timeout=5000;") != 0 { return false; }
    if hsql_exec(db.h, "PRAGMA journal_mode=WAL;") != 0 { return false; }
    if hsql_exec(db.h, "PRAGMA synchronous=NORMAL;") != 0 { return false; }
    if hsql_exec(db.h, "PRAGMA foreign_keys=ON;") != 0 { return false; }
    return true;
}

fn db_exec(db: Db&, sql: const u8[:]) -> bool {
    return hsql_exec(db.h, sql) == 0;
}

fn db_close(db: Db&) -> bool {
    let rc = hsql_close(db.h);
    db.h = 0;
    return rc == 0;
}

// Release process-wide SQLite state after every handle closed (call once
// from main after all workers joined; makes LSan fully clean).
fn db_shutdown() -> bool {
    return hsql_shutdown() == 0;
}

fn db_prepare(db: Db&, sql: const u8[:]) -> Stmt, bool {
    let h = hsql_prepare(db.h, sql);
    if h == 0 { return Stmt { h: 0 }, false; }
    return Stmt { h: h }, true;
}

fn stmt_finalize(st: Stmt&) -> bool {
    let rc = hsql_finalize(st.h);
    st.h = 0;
    return rc == 0;
}

fn stmt_step(st: Stmt&) -> i32 { hsql_step(st.h) }

fn stmt_reset(st: Stmt&) -> bool {
    if hsql_reset(st.h) != 0 { return false; }
    return hsql_clear_bindings(st.h) == 0;
}

fn bind_int(st: Stmt&, idx: i32, v: i64) -> bool {
    return hsql_bind_int(st.h, idx, v) == 0;
}

fn bind_float(st: Stmt&, idx: i32, v: f64) -> bool {
    return hsql_bind_float(st.h, idx, v) == 0;
}

// Safe default: SQLITE_TRANSIENT (SQLite copies; any lifetime OK).
fn bind_text(st: Stmt&, idx: i32, v: const u8[:]) -> bool {
    return hsql_bind_text(st.h, idx, v, 1) == 0;
}

// Zero-copy bind: caller guarantees v outlives step+reset (static or
// request scope). Misuse reads freed memory — prefer bind_text.
fn bind_text_static(st: Stmt&, idx: i32, v: const u8[:]) -> bool {
    return hsql_bind_text(st.h, idx, v, 0) == 0;
}

fn bind_null(st: Stmt&, idx: i32) -> bool {
    return hsql_bind_null(st.h, idx) == 0;
}

fn col_int(st: Stmt&, idx: i32) -> i64 { hsql_col_int(st.h, idx) }

fn col_float(st: Stmt&, idx: i32) -> f64 { hsql_col_float(st.h, idx) }

fn col_is_null(st: Stmt&, idx: i32) -> bool {
    return hsql_col_is_null(st.h, idx) != 0;
}

// Append the column's text once into out; returns the range (valid for the
// whole request scope). Check ok for misuse (null handle); NULL columns
// yield an empty range with ok == true (use col_is_null to distinguish).
fn col_text(st: Stmt&, idx: i32, out: u8[>..]&) -> const u8[:], bool {
    let start = out.len;
    let n = hsql_col_text(st.h, idx, out);
    if n < 0 { return "", false; }
    return out[start..], true;
}

fn db_last_id(db: Db&) -> i64 { hsql_last_id(db.h) }

fn db_changes(db: Db&) -> i64 { hsql_changes(db.h) }

// honk_sqlite.goose -- opt-in SQLite package (WAL + SQL-to-JSON + prepared Stmt).
//
// Declared beside honk_sqlite.build so apps need no .build file of their own:
//   import honk from "../..";
//   import honk_sqlite from "../../sqlite";

import std;
import json;
import honk from "..";

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
extern fn hsql_col_count(st: u64) -> i32;
extern fn hsql_col_type(st: u64, idx: i32) -> i32;
extern fn hsql_col_is_bool(st: u64, idx: i32) -> i32;
extern fn hsql_col_name(st: u64, idx: i32, out: u8[>..]&) -> i64;
extern fn hsql_last_id(db: u64) -> i64;
extern fn hsql_changes(db: u64) -> i64;
extern fn hsql_errcode(db: u64) -> i32;
extern fn hsql_errmsg(db: u64, out: u8[>..]&) -> i64;

let ROW: i32 = 100;
let DONE: i32 = 101;
let OPEN_READWRITE: i32 = 2;
let OPEN_CREATE: i32 = 4;
let OPEN_NOMUTEX: i32 = 32768;

struct Db { h: u64 }
struct Stmt { h: u64 }

fn db_is_open(db: Db&) -> bool { db.h != 0 }
fn stmt_is_ready(st: Stmt&) -> bool { st.h != 0 }

fn db_open(path: const u8[:]) -> Db, bool {
    let h = hsql_open(path, OPEN_READWRITE | OPEN_CREATE | OPEN_NOMUTEX);
    if h == 0 { return Db { h: 0 }, false; }
    return Db { h: h }, true;
}

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

// One-line setup: open + WAL/busy_timeout/foreign_keys + optional schema DDL.
fn db_connect(path: const u8[:], schema: const u8[:] = "") -> Db {
    let db, ok = db_open(path);
    guard ok else { abort("db_open failed"); }
    guard db_enable_wal(db) else { abort("db_enable_wal failed"); }
    if schema.len > 0 {
        guard db_exec(db, schema) else { abort("db schema exec failed"); }
    }
    return db;
}

fn db_close(db: Db&) -> bool {
    let rc = hsql_close(db.h);
    db.h = 0;
    return rc == 0;
}

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

fn bind_text(st: Stmt&, idx: i32, v: const u8[:]) -> bool {
    return hsql_bind_text(st.h, idx, v, 1) == 0;
}

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

fn col_text(st: Stmt&, idx: i32, out: u8[>..]&) -> const u8[:], bool {
    let start = out.len;
    let n = hsql_col_text(st.h, idx, out);
    if n < 0 { return "", false; }
    return out[start..], true;
}

fn db_last_id(db: Db&) -> i64 { hsql_last_id(db.h) }

fn db_changes(db: Db&) -> i64 { hsql_changes(db.h) }

let COL_INT: i32 = 1;
let COL_FLOAT: i32 = 2;
let COL_TEXT: i32 = 3;
let COL_BLOB: i32 = 4;
let COL_NULL: i32 = 5;

fn run_int(db: Db&, sql: const u8[:], id: i64) -> i64, bool {
    let st, ok = db_prepare(db, sql);
    if !ok { return 0, false; }
    let done = hsql_bind_int(st.h, 1, id) == 0 && hsql_step(st.h) == DONE;
    let n = if done { hsql_changes(db.h) } else { 0 };
    hsql_finalize(st.h);
    return n, done;
}

fn insert_text(db: Db&, sql: const u8[:], text: const u8[:]) -> i64, bool {
    let st, ok = db_prepare(db, sql);
    if !ok { return 0, false; }
    let done = hsql_bind_text(st.h, 1, text, 1) == 0 && hsql_step(st.h) == DONE;
    let id = if done { hsql_last_id(db.h) } else { 0 };
    hsql_finalize(st.h);
    return id, done;
}

fn col_name(st: Stmt&, idx: i32, out: u8[>..]&) -> const u8[:], bool {
    let start = out.len;
    let n = hsql_col_name(st.h, idx, out);
    if n < 0 { return "", false; }
    return out[start..], true;
}

// One row -> {"col":val,...} appended to stream. Columns declared BOOLEAN /
// BOOL in CREATE TABLE emit JSON true/false automatically.
fn row_to_json(app: honk::Ctx&, st: Stmt&, stream: u8[>..]&) -> bool {
    let ncols = hsql_col_count(st.h);
    if ncols < 0 { return false; }
    stream.push('{');
    var i: i32 = 0;
    while i < ncols {
        if i > 0 { stream.push(','); }
        let nm, nok = col_name(st, i, app.dstr);
        if !nok { return false; }
        json::format_key(stream, nm);
        let ty = hsql_col_type(st.h, i);
        if ty == COL_INT {
            if hsql_col_is_bool(st.h, i) != 0 {
                json::format_bool(stream, hsql_col_int(st.h, i) != 0);
            } else {
                json::format_int(stream, hsql_col_int(st.h, i));
            }
        } else if ty == COL_FLOAT {
            json::format_number(stream, hsql_col_float(st.h, i));
        } else if ty == COL_TEXT {
            let sstart = app.dstr.len;
            let n = hsql_col_text(st.h, i, app.dstr);
            if n < 0 { return false; }
            json::format_string(stream, app.dstr[sstart..]);
        } else if ty == COL_NULL {
            stream.append("null");
        } else {
            return false;
        }
        i++;
    }
    stream.push('}');
    return true;
}

inline fn sql_json(app: honk::Ctx&, db: Db&, sql: const u8[:]) {
    let st, ok = db_prepare(db, sql);
    if !ok {
        app.json_error(500, "query failed");
        return;
    }
    let start = app.tmp.len;
    app.tmp.push('[');
    var first = true;
    var failed = false;
    var rc = stmt_step(st);
    while rc == ROW {
        if !first { app.tmp.push(','); }
        first = false;
        if !row_to_json(app, st, app.tmp) { failed = true; break; }
        rc = stmt_step(st);
    }
    if rc != DONE { failed = true; }
    stmt_finalize(st);
    if failed {
        app.json_error(500, "query failed");
    } else {
        app.tmp.push(']');
        let rstart = app.res.len;
        app.res.append(app.tmp[start..]);
        app.json_raw(200, app.res[rstart..]);
    }
}

inline fn sql_json_one(app: honk::Ctx&, db: Db&, sql: const u8[:], id: i64) {
    let st, ok = db_prepare(db, sql);
    if !ok || hsql_bind_int(st.h, 1, id) != 0 {
        if ok { stmt_finalize(st); }
        app.json_error(500, "query failed");
        return;
    }
    let rc = stmt_step(st);
    if rc == ROW {
        let start = app.tmp.len;
        let good = row_to_json(app, st, app.tmp);
        let tail = stmt_step(st);
        stmt_finalize(st);
        if !good || (tail != DONE && tail != ROW) {
            app.json_error(500, "query failed");
            return;
        }
        let rstart = app.res.len;
        app.res.append(app.tmp[start..]);
        app.json_raw(200, app.res[rstart..]);
    } else {
        stmt_finalize(st);
        if rc == DONE {
            app.json_error(404, "not found");
        } else {
            app.json_error(500, "query failed");
        }
    }
}

inline fn sql_json_one_text(app: honk::Ctx&, db: Db&, sql: const u8[:], val: const u8[:]) {
    let st, ok = db_prepare(db, sql);
    if !ok || hsql_bind_text(st.h, 1, val, 1) != 0 {
        if ok { stmt_finalize(st); }
        app.json_error(500, "query failed");
        return;
    }
    let rc = stmt_step(st);
    if rc == ROW {
        let start = app.tmp.len;
        let good = row_to_json(app, st, app.tmp);
        let tail = stmt_step(st);
        stmt_finalize(st);
        if !good || (tail != DONE && tail != ROW) {
            app.json_error(500, "query failed");
            return;
        }
        let rstart = app.res.len;
        app.res.append(app.tmp[start..]);
        app.json_raw(200, app.res[rstart..]);
    } else {
        stmt_finalize(st);
        if rc == DONE {
            app.json_error(404, "not found");
        } else {
            app.json_error(500, "query failed");
        }
    }
}
// Allowlisted ORDER BY direction: "DESC" for `desc` (any case), else "ASC".
// SQL text must be 100% developer constants — user bytes enter ONLY through
// `?N` bindings. Identifiers (columns/tables) need an allowlist branch in
// app code; directions go through here. NEVER append raw input to SQL.
inline fn order_dir(s: const u8[:]) -> const u8[:] {
    if s.len == 4 {
        let w = "desc";
        var ok = true;
        for k in 4 {
            if !honk::eq_ci(s[k], w[k]) { ok = false; break; }
        }
        if ok { return "DESC"; }
    }
    return "ASC";
}

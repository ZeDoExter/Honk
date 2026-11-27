// test/app_fullstack.goose -- static files + SQLite for test_fullstack.py.
// Usage: ./app_fullstack [port] [static_root] [num_workers] [db_path]
// Static root travels to workers as a fixed-size array (threads share
// nothing). SQLite: one WAL connection + prepared statements per worker,
// captured by the request block; finalized + closed after serve returns.

import std;
import os;
import json;
import honk from "..";
import honk_sqlite from "../sqlite";

struct P5WorkerCfg {
    port: i32,
    worker_id: i32,
    cpu_id: i32,
    root: u8[256],
    root_len: i64,
    dbpath: u8[256],
    dbpath_len: i64,
}

struct DbUser { name: const u8[:], has_name: bool, age: i64, has_age: bool }

fn parse_dbuser(r: json::Reader&, scratch: u8[>..]&, u: DbUser&) -> bool {
    json::each_member(r) { key =>
        if key == "name" {
            u.name = json::read_string(r, scratch);
            u.has_name = true;
        } else if key == "age" {
            u.age = json::read_int(r);
            u.has_age = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) { return false; }
    if !u.has_name || !u.has_age { return false; }
    return true;
}

thread_fn p5_worker(cfg: P5WorkerCfg) {
    assert(cfg.root_len >= 0 && cfg.root_len <= 256);
    assert(cfg.dbpath_len >= 0 && cfg.dbpath_len <= 256);
    let root = cfg.root[..cfg.root_len];
    var scfg = honk::Config {
        port: cfg.port,
        worker_id: cfg.worker_id,
        cpu_id: cfg.cpu_id,
        ..
    };
    honk::listen_cfg_or_abort(scfg);
    // Per-worker SQLite state (captured by routes; see GUIDE worker pattern).
    // NOTE: schema DDL runs once in main (below), not here: concurrent DDL
    // from two workers can abort with SQLITE_SCHEMA, which busy_timeout does
    // not cover. Workers only open + set WAL + prepare (all race-safe).
    let dbpath = cfg.dbpath[..cfg.dbpath_len];
    let db, dbok = db_open(dbpath);
    guard dbok else { abort("db_open failed"); }
    guard db_enable_wal(db) else { abort("wal setup failed"); }
    let st_ins, iok = db_prepare(db, "INSERT INTO kv(name, age) VALUES (?1, ?2);");
    let st_upd, uok = db_prepare(db, "UPDATE kv SET name = ?1, age = ?2 WHERE id = ?3;");
    let st_del, dok = db_prepare(db, "DELETE FROM kv WHERE id = ?1;");
    guard iok && uok && dok else { abort("prepare failed"); }

    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.method == "POST" && ctx.path == "/__shutdown" {
                honk_request_stop();
                ctx.keep_alive = false;
                ctx.text(200, "shutting down");
            } else if ctx.method == "POST" && ctx.path == "/db" {
                var u = DbUser { name: "", .. };
                var r = json::reader(ctx.body);
                if !parse_dbuser(r, ctx.tmp, u) || u.name.len == 0 {
                    ctx.json_error(400, "name (string) and age (int) required");
                } else if !bind_text(st_ins, 1, u.name) || !bind_int(st_ins, 2, u.age) {
                    stmt_reset(st_ins);
                    ctx.json_error(500, "bind failed");
                } else if stmt_step(st_ins) != DONE {
                    stmt_reset(st_ins);
                    ctx.json_error(500, "insert failed");
                } else {
                    let id = db_last_id(db);
                    stmt_reset(st_ins);
                    ctx.res.append("{\"id\":");
                    format(ctx.res, id);
                    ctx.res.push('}');
                    ctx.json_raw(201, ctx.res[..]);
                }
            } else if ctx.method == "GET" && ctx.path == "/db" {
                let raw, rok = ctx.query("id");
                if !rok {
                    ctx.json_error(400, "missing id");
                } else {
                    let id, iok2 = honk::parse_i64_strict(raw);
                    if !iok2 || id <= 0 {
                        ctx.json_error(400, "bad id");
                    } else {
                        ctx.sql_json_one(db, "SELECT id, name, age FROM kv WHERE id = ?1;", id);
                    }
                }
            } else if ctx.method == "GET" && ctx.path == "/db/all" {
                ctx.sql_json(db, "SELECT id, name, age FROM kv ORDER BY id;");
            } else if ctx.method == "GET" && ctx.path == "/db/by-name" {
                let nm, nok = ctx.query_decoded("name");
                if !nok || nm.len == 0 {
                    ctx.json_error(400, "missing name");
                } else {
                    ctx.sql_json_one_text(db, "SELECT id, name, age FROM kv WHERE name = ?1 ORDER BY id LIMIT 1;", nm);
                }
            } else if ctx.method == "GET" && ctx.path == "/db/search" {
                let nm, nok = ctx.query_decoded("name");
                if !nok || nm.len == 0 {
                    ctx.json_error(400, "missing name");
                } else {
                    var pat: u8[>..] = [];
                    pat.push('%');
                    like_escape(nm, pat);
                    pat.push('%');
                    ctx.sql_json_text(db, "SELECT id, name, age FROM kv WHERE name LIKE ?1 ESCAPE '\\' ORDER BY id;", pat[..]);
                }
            } else if ctx.method == "GET" && ctx.path == "/db/sorted" {
                let by = ctx.query_str_or("by", "id");
                let col = if by == "name" { "name" } else if by == "age" { "age" } else { "id" };
                let dir = order_dir(ctx.query_str_or("dir", "asc"));
                var sql: u8[>..] = [];
                sql.append("SELECT id, name, age FROM kv ORDER BY ");
                sql.append(col);
                sql.push(' ');
                sql.append(dir);
                sql.push(';');
                ctx.sql_json(db, sql[..]);
            } else if ctx.method == "PUT" && ctx.path == "/db" {
                let raw, rok = ctx.query("id");
                if !rok {
                    ctx.json_error(400, "missing id");
                } else {
                    let id, iok3 = honk::parse_i64_strict(raw);
                    var u = DbUser { name: "", .. };
                    var r = json::reader(ctx.body);
                    if !iok3 || id <= 0 || !parse_dbuser(r, ctx.tmp, u) || u.name.len == 0 {
                        ctx.json_error(400, "id + name (string) + age (int) required");
                    } else if !bind_text(st_upd, 1, u.name) || !bind_int(st_upd, 2, u.age) || !bind_int(st_upd, 3, id) {
                        stmt_reset(st_upd);
                        ctx.json_error(500, "bind failed");
                    } else if stmt_step(st_upd) != DONE {
                        stmt_reset(st_upd);
                        ctx.json_error(500, "update failed");
                    } else if db_changes(db) == 0 {
                        stmt_reset(st_upd);
                        ctx.json_error(404, "not found");
                    } else {
                        stmt_reset(st_upd);
                        ctx.json_raw(200, "{\"ok\":true}");
                    }
                }
            } else if ctx.method == "DELETE" && ctx.path == "/db" {
                let raw, rok = ctx.query("id");
                if !rok {
                    ctx.json_error(400, "missing id");
                } else {
                    let id, iok4 = honk::parse_i64_strict(raw);
                    if !iok4 || id <= 0 {
                        ctx.json_error(400, "bad id");
                    } else if !bind_int(st_del, 1, id) {
                        stmt_reset(st_del);
                        ctx.json_error(500, "bind failed");
                    } else if stmt_step(st_del) != DONE {
                        stmt_reset(st_del);
                        ctx.json_error(500, "delete failed");
                    } else if db_changes(db) == 0 {
                        stmt_reset(st_del);
                        ctx.json_error(404, "not found");
                    } else {
                        stmt_reset(st_del);
                        ctx.json_raw(200, "{\"ok\":true}");
                    }
                }
            } else if try_serve_file(ctx, root, true) {
                // Static handled (200/HEAD/405 staged).
            } else {
                ctx.text(404, "Not Found");
            }
        };
    };

    stmt_finalize(st_ins);
    stmt_finalize(st_upd);
    stmt_finalize(st_del);
    db_close(db);
}

fn main() {
    var port: i32 = 18080;
    var num_workers: i32 = 1;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    if a.len > 3 {
        if a[3] == "fork2" {
            num_workers = -2;
        } else if a[3] == "badfork" {
            num_workers = -99;
        } else {
            let v, ok = parse_int(a[3]);
            if ok { num_workers = v as! i32; }
        }
    }
    assert((num_workers >= 1 && num_workers <= 4) || num_workers == -2 || num_workers == -99);
    // Static root copied byte-wise (argv/static roots must not mix).
    var rootbuf: u8[256] = [0; 256];
    var root_len: i64 = 0;
    if a.len > 2 {
        let r = a[2];
        if r.len > 255 { abort("static root too long (max 255)"); }
        for b, i in r { rootbuf[i] = b; }
        root_len = r.len;
    } else {
        let d = "test/static_fixtures";
        for b, i in d { rootbuf[i] = b; }
        root_len = d.len;
    }
    // DB path copied byte-wise (argv/static roots must not mix).
    var dbbuf: u8[256] = [0; 256];
    var db_len: i64 = 0;
    if a.len > 4 {
        let r = a[4];
        if r.len > 255 { abort("db path too long (max 255)"); }
        for b, i in r { dbbuf[i] = b; }
        db_len = r.len;
    } else {
        let d = "build/fullstack_test.db";
        for b, i in d { dbbuf[i] = b; }
        db_len = d.len;
    }
    // Schema once, single-threaded, before workers spawn (avoids DDL races).
    // Workers open their own handles afterwards; main's handle is closed here.
    {
        let mdb, mok = db_open(dbbuf[..db_len]);
        guard mok else { abort("main db_open failed"); }
        guard db_enable_wal(mdb) else { abort("main wal setup failed"); }
        guard db_exec(mdb, "CREATE TABLE IF NOT EXISTS kv(id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER NOT NULL);") else { abort("main ddl failed"); }
        if num_workers == -99 {
            // Intentional misuse test: forking while mdb is still open must abort.
            honk::workers(2);
        }
        db_close(mdb);
    }
    if num_workers == -2 {
        print("app_fullstack fork2 listening on port ", port);
        flush_stdout();
        honk::workers(2);
        let db, dbok = db_open(dbbuf[..db_len]);
        guard dbok && db_enable_wal(db) else { abort("fork db setup failed"); }
        honk::listen(port) { app =>
            app.get("/db/all") {
                app.sql_json(db, "SELECT id, name, age FROM kv ORDER BY id;");
            };
            app.post("/db") {
                app.require_str("name") { nm =>
                    let age, aok = app.body_int("age");
                    if !aok {
                        app.json_error(400, "age required");
                    } else {
                        let id, iok = insert_text(db, "INSERT INTO kv(name, age) VALUES (?1, 0);", nm);
                        let _, uok = run_int(db, "UPDATE kv SET age = age WHERE id = ?1;", id);
                        if !iok || !uok {
                            app.json_error(500, "insert failed");
                        } else {
                            app.created_json() { j =>
                                j.int("id", id);
                                j.int("worker", honk_worker_id() as! i64);
                                j.int("age", age);
                            };
                        }
                    }
                };
            };
        };
        db_close(db);
        db_shutdown();
        return;
    }
    print("app_fullstack listening on port ", port);
    flush_stdout();
    var tids: i64[..4] = [];
    for w in num_workers {
        let cfg = P5WorkerCfg {
            port: port,
            worker_id: w,
            cpu_id: w * 2,
            root: rootbuf,
            root_len: root_len,
            dbpath: dbbuf,
            dbpath_len: db_len,
        };
        tids.push(thread_spawn(p5_worker, cfg));
    }
    for tid in tids { thread_wait(tid); }
    db_shutdown();
}

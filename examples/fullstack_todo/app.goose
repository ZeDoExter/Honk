// examples/fullstack_todo/app.goose -- single-binary Todo app.
//
// Serves public/ (HTML/CSS/JS) via kernel sendfile + a JSON API backed by
// per-worker SQLite (WAL + prepared statements). Run from THIS directory
// (dev does that for you) so "public" and "todos.db" resolve:
//
//   ./honk dev examples/fullstack_todo     (http://127.0.0.1:18080/)
//   ./honk build examples/fullstack_todo --release

import std;
import os;
import json;
import honk_net from "../../src/honk_net";
import honk_ctx from "../../src/honk_ctx";
import honk_serve from "../../src/honk_serve";
import honk_static from "../../src/honk_static";
import honk_sqlite from "../../src/honk_sqlite";

struct NewTodo { title: const u8[:], has_title: bool }

fn parse_newtodo(r: json::Reader&, scratch: u8[>..]&, t: NewTodo&) -> bool {
    json::each_member(r) { key =>
        if key == "title" {
            t.title = json::read_string(r, scratch);
            t.has_title = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) { return false; }
    if !t.has_title { return false; }
    return true;
}

thread_fn worker(port: i32) {
    honk::listen_or_abort(port);

    // Per-worker database (captured by the API routes below).
    let db, dbok = db_open("todos.db");
    guard dbok else { abort("db_open failed"); }
    guard db_enable_wal(db) else { abort("wal setup failed"); }
    guard db_exec(db, "CREATE TABLE IF NOT EXISTS todos(id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0);") else { abort("ddl failed"); }
    let st_all, aok = db_prepare(db, "SELECT id, title, done FROM todos ORDER BY id;");
    let st_ins, iok = db_prepare(db, "INSERT INTO todos(title, done) VALUES (?1, 0);");
    let st_tog, tok = db_prepare(db, "UPDATE todos SET done = 1 - done WHERE id = ?1;");
    let st_del, dok = db_prepare(db, "DELETE FROM todos WHERE id = ?1;");
    guard aok && iok && tok && dok else { abort("prepare failed"); }

    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.method == "GET" && ctx.path == "/api/todos" {
                ctx.res.push('[');
                var first = true;
                var rc = stmt_step(st_all);
                var failed = false;
                while rc == ROW {
                    if !first { ctx.res.push(','); }
                    first = false;
                    let nm, nok = col_text(st_all, 1, ctx.tmp);
                    if !nok { failed = true; break; }
                    ctx.res.append("{\"id\":");
                    format(ctx.res, col_int(st_all, 0));
                    ctx.res.append(",\"title\":");
                    json::format_string(ctx.res, nm);
                    ctx.res.append(",\"done\":");
                    json::format_bool(ctx.res, col_int(st_all, 2) != 0);
                    ctx.res.push('}');
                    rc = stmt_step(st_all);
                }
                if rc != DONE { failed = true; }
                stmt_reset(st_all);
                if failed {
                    ctx.json_error(500, "select failed");
                } else {
                    ctx.res.push(']');
                    ctx.json_raw(200, ctx.res[..]);
                }
            } else if ctx.method == "POST" && ctx.path == "/api/todos" {
                var t = NewTodo { title: "", .. };
                var r = json::reader(ctx.body);
                if !parse_newtodo(r, ctx.tmp, t) || t.title.len == 0 {
                    ctx.json_error(400, "title (non-empty string) required");
                } else if !bind_text(st_ins, 1, t.title) {
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
                    ctx.res.append(",\"title\":");
                    json::format_string(ctx.res, t.title);
                    ctx.res.append(",\"done\":false}");
                    ctx.json_raw(201, ctx.res[..]);
                }
            } else if ctx.method == "PATCH" {
                // /api/todos/:id/toggle
                let rest, ok = ctx.rest("/api/todos/");
                if ok && rest.len > 7 && rest[rest.len - 7 ..] == "/toggle" {
                    let idpart = rest[..rest.len - 7];
                    let vid, vok = parse_i64_strict(idpart);
                    if vok && vid > 0 && bind_int(st_tog, 1, vid) && stmt_step(st_tog) == DONE {
                        let changed = db_changes(db);
                        stmt_reset(st_tog);
                        if changed == 0 {
                            ctx.json_error(404, "not found");
                        } else {
                            ctx.json_raw(200, "{\"ok\":true}");
                        }
                    } else {
                        stmt_reset(st_tog);
                        ctx.json_error(400, "bad id");
                    }
                } else {
                    ctx.json_error(404, "not found");
                }
            } else if ctx.method == "DELETE" {
                let seg, ok = match_1param(ctx.path, "/api/todos/");
                if ok {
                    let vid, vok = parse_i64_strict(seg);
                    if vok && vid > 0 && bind_int(st_del, 1, vid) && stmt_step(st_del) == DONE {
                        let changed = db_changes(db);
                        stmt_reset(st_del);
                        if changed == 0 {
                            ctx.json_error(404, "not found");
                        } else {
                            ctx.json_raw(200, "{\"ok\":true}");
                        }
                    } else {
                        stmt_reset(st_del);
                        ctx.json_error(400, "bad id");
                    }
                } else {
                    ctx.json_error(404, "not found");
                }
            } else if ctx.method == "POST" && ctx.path == "/__shutdown" {
                honk_request_stop();
                ctx.keep_alive = false;
                ctx.text(200, "shutting down");
            } else if (ctx.method == "GET" || ctx.head_only) && try_serve_file(ctx, "public", true) {
                // Static frontend served (200/HEAD staged).
            } else if (ctx.method == "GET" || ctx.head_only) && serve_rel(ctx, "public", "index.html", false) {
                // SPA fallback: unknown GET routes boot index.html.
            } else {
                ctx.json_error(404, "not found");
            }
        };
    };

    stmt_finalize(st_all);
    stmt_finalize(st_ins);
    stmt_finalize(st_tog);
    stmt_finalize(st_del);
    db_close(db);
}

fn main() {
    var port: i32 = 18080;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    print("fullstack_todo listening on port ", port, " (run from examples/fullstack_todo/)");
    flush_stdout();
    let tid = thread_spawn(worker, port);
    thread_wait(tid);
    db_shutdown();
}

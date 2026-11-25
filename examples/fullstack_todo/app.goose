// examples/fullstack_todo/app.goose -- Todo API + static SPA on the App DSL.
//
// Same routes, statuses, and shapes as before, in ~60 lines: sql_json-style
// manual GET (the `done` column reshapes to a JSON bool), one-shot
// insert_text/run_int mutations, typed DELETE, static_dir + SPA fallback.
//   ./honk dev examples/fullstack_todo     (http://127.0.0.1:18080/)
//   ./honk build examples/fullstack_todo --release
// NOTE: blocks are inlined: never `return`/`break` inside them; use if/else.

import std;
import os;
import json;
import honk from "../../src";
import honk.honk_sqlite.honk_sqlite;

fn main() {
    var port: i32 = 18080;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    let db, dbok = db_open("todos.db");
    guard dbok else { abort("db_open failed"); }
    guard db_enable_wal(db) else { abort("wal setup failed"); }
    guard db_exec(db, "CREATE TABLE IF NOT EXISTS todos(id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0);") else { abort("ddl failed"); }
    let st_all, aok = db_prepare(db, "SELECT id, title, done FROM todos ORDER BY id;");
    guard aok else { abort("prepare failed"); }
    print("fullstack_todo listening on port ", port, " (run from examples/fullstack_todo/)");
    flush_stdout();
    honk::listen(port) { app =>
        app.get("/api/todos") {
            app.res.push('[');
            var first = true;
            var rc = stmt_step(st_all);
            var failed = false;
            while rc == ROW {
                if !first { app.res.push(','); }
                first = false;
                let nm, nok = col_text(st_all, 1, app.tmp);
                if !nok { failed = true; break; }
                app.res.append("{\"id\":");
                format(app.res, col_int(st_all, 0));
                app.res.append(",\"title\":");
                json::format_string(app.res, nm);
                app.res.append(",\"done\":");
                json::format_bool(app.res, col_int(st_all, 2) != 0);
                app.res.push('}');
                rc = stmt_step(st_all);
            }
            if rc != DONE { failed = true; }
            stmt_reset(st_all);
            if failed {
                app.json_error(500, "select failed");
            } else {
                app.res.push(']');
                app.json_raw(200, app.res[..]);
            }
        };
        app.post("/api/todos") {
            let t, tok = app.body_str("title");
            if !tok || t.len == 0 {
                app.json_error(400, "title (non-empty string) required");
            } else {
                let id, ok = insert_text(db, "INSERT INTO todos(title, done) VALUES (?1, 0);", t);
                if !ok {
                    app.json_error(500, "insert failed");
                } else {
                    app.created_json() { j =>
                        j.int("id", id);
                        j.str("title", t);
                        j.jbool("done", false);
                    };
                }
            }
        };
        app.patch_wild("/api/todos/") { rest =>
            if rest.len > 7 && rest[rest.len - 7 ..] == "/toggle" {
                let vid, vok = honk::parse_i64_strict(rest[..rest.len - 7]);
                let n, ok = run_int(db, "UPDATE todos SET done = 1 - done WHERE id = ?1;", vid);
                if !vok || vid <= 0 || !ok {
                    app.json_error(400, "bad id");
                } else if n == 0 {
                    app.json_error(404, "not found");
                } else {
                    app.ok_json();
                }
            } else {
                app.json_error(404, "not found");
            }
        };
        app.delete_int("/api/todos/:id") { vid =>
            let n, ok = run_int(db, "DELETE FROM todos WHERE id = ?1;", vid);
            if !ok {
                app.json_error(400, "bad id");
            } else if n == 0 {
                app.json_error(404, "not found");
            } else {
                app.ok_json();
            }
        };
        app.post("/__shutdown") {
            honk_request_stop();
            app.keep_alive = false;
            app.text(200, "shutting down");
        };
        app.static_dir("/", "public");
        app.get_wild("/*") { _r =>
            serve_rel(app, "public", "index.html", false);
        };
    };
    stmt_finalize(st_all);
    db_close(db);
    db_shutdown();
}

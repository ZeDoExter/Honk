// examples/fullstack_todo/app.goose -- Fullstack Todo API + SPA (~38 lines, no .build).
//   ./honk dev examples/fullstack_todo     (http://127.0.0.1:18080/)

import std;
import honk from "../..";
import honk_sqlite from "../../sqlite";

fn main() {
    let port = honk::arg_port(18080);
    let db = db_connect("todos.db",
        "CREATE TABLE IF NOT EXISTS todos(id INTEGER PRIMARY KEY, title TEXT NOT NULL, done BOOLEAN NOT NULL DEFAULT 0);");
    print("fullstack_todo listening on port ", port, " (run from examples/fullstack_todo/)");
    flush_stdout();
    honk::listen(port) { app =>
        app.get("/api/todos") {
            app.sql_json(db, "SELECT id, title, done FROM todos ORDER BY id;");
        };
        app.post("/api/todos") {
            app.require_str("title") { t =>
                let id, ok = insert_text(db, "INSERT INTO todos(title) VALUES (?1);", t);
                if !ok { app.json_error(500, "insert failed"); }
                else { app.created_json() { j => j.set("id", id); j.set("title", t); j.set("done", false); }; }
            };
        };
        app.patch_int("/api/todos/:id/toggle") { id =>
            let n, ok = run_int(db, "UPDATE todos SET done = 1 - done WHERE id = ?1;", id);
            if !ok || id <= 0 { app.json_error(400, "bad id"); }
            else if n == 0 { app.json_error(404, "not found"); }
            else { app.ok_json(); }
        };
        app.delete_int("/api/todos/:id") { id =>
            let n, ok = run_int(db, "DELETE FROM todos WHERE id = ?1;", id);
            if !ok { app.json_error(400, "bad id"); }
            else if n == 0 { app.json_error(404, "not found"); }
            else { app.ok_json(); }
        };
        app.static_dir("/", "public");
        app.get("/*") { serve_rel(app, "public", "index.html", false); };
    };
    db_close(db);
    db_shutdown();
}

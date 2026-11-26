// examples/chat/app.goose -- multi-room chat on non-blocking WebSockets.
//   ./honk dev examples/chat     (http://127.0.0.1:18080/)
//
// Exercises v1.0 end to end: WS rooms + query-token auth + SQLite history +
// per-message rate limits. NOTE: single worker only (room members live in a
// process-local global; run without $HONK_WORKERS).
import std;
import json;
import honk from "../..";
import honk.src.honk_auth.honk_auth;
import honk.src.honk_ws.honk_ws;
import honk_sqlite from "../../sqlite";

struct Member { fd: i32, room_hash: u64 }

var members: Member[256] = [Member { fd: -1, room_hash: 0 }; 256];

inline fn fnv1a(s: const u8[:]) -> u64 {
    var h: u64 = 14695981039346656037;
    for b in s {
        h = (h ^ b) * 1099511628211;
    }
    return h;
}

fn member_add(fd: i32, rh: u64) -> bool {
    for i in 256 {
        if members[i].fd < 0 {
            members[i].fd = fd;
            members[i].room_hash = rh;
            return true;
        }
    }
    return false;
}

inline fn member_has(fd: i32) -> bool {
    for i in 256 {
        if members[i].fd == fd { return true; }
    }
    return false;
}

fn chat_broadcast(app: honk::Ctx&, msg: const u8[:], ws: honk::Ws&, db: Db&) {
    let room = app.param("room");
    let rh = fnv1a(room);
    if !member_has(ws.fd) {
        if !member_add(ws.fd, rh) {
            ws.close(1013);
            return;
        }
    }
    if msg.len == 0 || msg.len > 512 {
        return;
    }
    let st, ok = db_prepare(db, "INSERT INTO msgs(room, usr, text) VALUES (?1, ?2, ?3);");
    if ok {
        let done = bind_text(st, 1, room) && bind_text(st, 2, app.user) && bind_text(st, 3, msg) && stmt_step(st) == DONE;
        stmt_finalize(st);
        if !done { return; }
    }
    let start = app.res.len;
    app.res.append("{\"user\":");
    json::format_string(app.res, app.user);
    app.res.append(",\"text\":");
    json::format_string(app.res, msg);
    app.res.push('}');
    let payload = app.res[start..];
    for i in 256 {
        if members[i].fd >= 0 && members[i].room_hash == rh && members[i].fd != ws.fd {
            if !honk::ws_send_frame(members[i].fd, 1, payload) {
                members[i].fd = -1;
            }
        }
    }
}

fn main() {
    let secret = "dev-secret-change-me";
    let db = db_connect("chat.db",
        "CREATE TABLE IF NOT EXISTS msgs(id INTEGER PRIMARY KEY, room TEXT NOT NULL, usr TEXT NOT NULL, text TEXT NOT NULL);");
    let port = honk::arg_port(18080);
    print("chat listening on port ", port, " (single worker; run from examples/chat/)");
    flush_stdout();
    honk::listen(port) { app =>
        app.json_errors();
        app.rate_limit(120, 60);

        app.post("/login") {
            app.require_str_len("user", 1, 32) { u =>
                let tok = app.jwt_issue(secret, u, 86400);
                app.json() { j => j.set("token", tok); };
            };
        };

        app.get("/history/:room") {
            let st, ok = db_prepare(db, "SELECT usr, text FROM msgs WHERE room = ?1 ORDER BY id DESC LIMIT 50;");
            if !ok || !bind_text(st, 1, app.param("room")) {
                if ok { stmt_finalize(st); }
                app.json_error(500, "query failed");
            } else {
                let start = app.res.len;
                app.res.push('[');
                var first = true;
                var rc = stmt_step(st);
                while rc == ROW {
                    if !first { app.res.push(','); }
                    first = false;
                    let nm, nok = col_text(st, 0, app.tmp);
                    let tx, tok = col_text(st, 1, app.tmp);
                    if !nok || !tok { break; }
                    app.res.push('{');
                    json::format_key(app.res, "user");
                    json::format_string(app.res, nm);
                    app.res.push(',');
                    json::format_key(app.res, "text");
                    json::format_string(app.res, tx);
                    app.res.push('}');
                    rc = stmt_step(st);
                }
                stmt_finalize(st);
                app.res.push(']');
                app.json_raw(200, app.res[start..]);
            }
        };

        app.group("/ws") {
            // Query-token auth at handshake; message turns reuse aux identity.
            if !app.ws_msg {
                let tok = app.query_str_or("token", "");
                let claims, vok = honk::jwt_verify(tok, secret, app.tmp);
                if !vok {
                    app.json_error(401, "bad token");
                    app.handled = true;
                } else {
                    let sub, sok = app.jwt_claim_str(claims, "sub");
                    if sok { app.user = sub; }
                    app.authed = true;
                }
            }
            app.ws("/:room") { msg, ws =>
                chat_broadcast(app, msg, ws, db);
            };
        };

        app.static_dir("/", "public");
    };
    db_close(db);
    db_shutdown();
}

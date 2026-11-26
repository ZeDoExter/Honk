// test/app_net.goose -- bind-spec + dual-stack + unix-socket exercise app.
// Usage: ./app_net <port> [workers] | ./app_net unix:/path.sock [workers]
import std;
import os;
import honk from "..";
import honk.src.honk_ws.honk_ws;

fn net_routes(app: honk::Ctx&) {
    app.get("/my-ip") { app.ok(app.client_ip()); };
    app.ws("/ws") { msg, ws => ws.send(msg); };
    app.post("/__shutdown") {
        honk_request_stop();
        app.text(200, "bye");
    };
}

fn main() {
    let a = args();
    let target = if a.len > 1 { a[1] } else { "18080" };
    var workers: i32 = -1;
    if a.len > 2 {
        let v, ok = parse_int(a[2]);
        if ok { workers = v as! i32; }
    }
    print("app_net on ", target);
    flush_stdout();
    if target.len >= 5 && target[..5] == "unix:" {
        if workers >= 0 { honk::workers(workers); }
        honk::listen_at(target, 0) { app => net_routes(app); };
    } else {
        let port = honk::arg_port(18080);
        if workers >= 0 {
            honk::listen_workers(port, workers) { app => net_routes(app); };
        } else {
            honk::listen(port) { app => net_routes(app); };
        }
    }
}

// examples/quickstart/app.goose -- minimal realistic Honk application.
//
// Routes, :params, ?query, bearer guard, validated JSON POST — no transport
// code: honk::listen owns workers, buffers, emit, and shutdown.
//
// Build:  goose build examples/quickstart/app.goose -o examples/quickstart/app
// Run:    ./examples/quickstart/app [port]
// NOTE: blocks are inlined: never `return`/`break` inside them; use if/else.

import std;
import os;
import honk from "../../src";

fn main() {
    var port: i32 = 18080;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    print("quickstart listening on port ", port);
    flush_stdout();
    honk::listen(port) { app =>
        app.get_text("/", "Welcome to Honk! Try /hello/ada?title=Dr, /private, /signup");
        app.get_param("/hello/:name") { name =>
            let title = app.query_str_or("title", "");
            app.res.append("Hello, ");
            if title.len > 0 {
                app.res.append(title);
                app.res.push(' ');
            }
            app.res.append(name);
            app.res.push('!');
            app.text(200, app.res[..]);
        };
        app.get("/private") {
            let tok, ok = app.bearer_token();
            if !ok {
                app.text(401, "Unauthorized");
            } else {
                app.res.append("hello ");
                app.res.append(tok);
                app.res.append(", this route is guarded");
                app.text(200, app.res[..]);
            }
        };
        app.post("/signup") {
            app.require_str("username") { u =>
                app.require_str("email") { e =>
                    let age, has_age = app.body_int("age");
                    app.json() { j =>
                        j.jbool("created", true);
                        j.str("username", u);
                        j.str("email", e);
                        if has_age {
                            j.int("age", age);
                        }
                    };
                };
            };
        };
        app.post("/__shutdown") {
            honk_request_stop();
            app.keep_alive = false;
            app.text(200, "shutting down");
        };
    };
}

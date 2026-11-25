// examples/quickstart/app.goose -- minimal realistic Honk application.
//
// Run:    ./honk dev examples/quickstart
// Build:  ./honk build examples/quickstart --release

import std;
import honk from "../..";

fn main() {
    let port = honk::arg_port(18080);
    print("quickstart listening on port ", port);
    flush_stdout();
    honk::listen(port) { app =>
        app.get("/", "Welcome to Honk! Try /hello/ada?title=Dr, /private, /signup");
        app.get("/hello/:name") {
            let title = app.query_str_or("title", "");
            app.res.append("Hello, ");
            if title.len > 0 {
                app.res.append(title);
                app.res.push(' ');
            }
            app.res.append(app.param("name"));
            app.res.push('!');
            app.ok(app.res[..]);
        };
        app.get("/private") {
            let tok, ok = app.bearer_token();
            if !ok {
                app.text(401, "Unauthorized");
            } else {
                app.res.append("hello ");
                app.res.append(tok);
                app.res.append(", this route is guarded");
                app.ok(app.res[..]);
            }
        };
        app.post("/signup") {
            app.require_str("username") { u =>
                app.require_str("email") { e =>
                    let age, has_age = app.body_int("age");
                    app.json() { j =>
                        j.set("created", true);
                        j.set("username", u);
                        j.set("email", e);
                        if has_age { j.set("age", age); }
                    };
                };
            };
        };
    };
}

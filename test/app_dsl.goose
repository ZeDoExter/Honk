// test/app_dsl.goose -- exercises unified pattern routing, named/indexed
// params, suffix *_int routes, overloaded j.set, SIGINT/SIGTERM drain, and
// HONK_WORKERS / listen_workers fork scaling.
// Usage: ./app_dsl [port] [explicit_workers]

import std;
import os;
import honk from "..";

fn dsl_routes(app: honk::Ctx&) {
    app.get("/", "dsl root");
    app.get_text("/txt", "plain literal");
    app.get_json_raw("/jraw", "{\"raw\":1}");

    // First-match-wins: second handler on the same method+path must not run.
    app.get("/first", "winner");
    app.get("/first", "loser");

    app.get("/wid") {
        app.json() { j =>
            j.set("worker", honk_worker_id() as! i64);
        };
    };

    // Overloaded j.set (str, i64, f64, bool) + jnull + raw.
    app.get("/jtypes") {
        app.json() { j =>
            j.set("s", "a\"b");
            j.set("i", -9);
            j.set("f", 2.5);
            j.set("b", true);
            j.jnull("n");
            j.raw("r", "[1,2]");
        };
    };

    app.post("/echo-json") {
        let s, sok = app.body_str("s");
        let n, nok = app.body_int("n");
        let b, bok = app.body_bool("b");
        if !sok || !nok || !bok {
            app.json_error(400, "missing typed fields");
        } else {
            app.created_json() { j =>
                j.set("s", s);
                j.set("n", n);
                j.set("b", b);
            };
        }
    };

    app.post("/req-str") {
        app.require_str("title") { t =>
            app.ok(t);
        };
    };

    app.put("/item") { app.ok_json(); };
    app.patch("/item") { app.ok("patched"); };
    app.delete("/item") { app.no_content(); };

    // Unified pattern routing: named app.param("..."), app.param(0), suffix, /*
    app.get("/p/:slug") {
        app.ok(app.param("slug"));
    };
    app.get("/orgs/:org/repos/:repo") {
        app.json() { j =>
            j.set("org", app.param("org"));
            j.set("repo", app.param("repo"));
            j.set("first_idx", app.param(0));
        };
    };
    app.get("/w/*") {
        app.ok(app.tail);
    };

    // Typed *_int routes across all methods, including literal suffixes!
    app.get_int("/i/:id") { id =>
        app.json() { j => j.set("id", id); };
    };
    app.post_int("/i/:id/clone") { id =>
        app.created_json() { j => j.set("cloned", id); };
    };
    app.put_int("/i/:id/publish") { id =>
        app.json() { j => j.set("published", id); };
    };
    app.patch_int("/i/:id/toggle") { id =>
        app.json() { j => j.set("toggled", id); };
    };
    app.patch_int("/i/:id") { id =>
        app.json() { j => j.set("patched", id); };
    };
    app.delete_int("/i/:id") { id =>
        app.json() { j => j.set("deleted", id); };
    };

    // Legacy compat aliases
    app.get_param("/compat/p/:x") { x => app.ok(x); };
    app.get2("/compat/a/:x/b/:y") { x, y =>
        app.json() { j => j.str("x", x); j.str("y", y); };
    };
    app.get_wild("/compat/w/*") { rest => app.ok(rest); };
    app.patch_wild("/pw/") { rest => app.ok(rest); };

    // v0.4.0: nested group + bearer + nested JSON + named-field range validator
    app.group("/v1") {
        app.get("/tree") {
            app.json() { j =>
                j.obj("meta") { m => m.set("ver", 4); };
                j.arr("items") { a => a.add("x"); a.add("y"); };
            };
        };
        app.post("/age-check") {
            app.require_int_range("age", 1, 130) { age =>
                app.json() { j => j.set("age", age); };
            };
        };
        app.group("/sec") {
            app.bearer() { tok =>
                app.get("/who") { app.ok(tok); };
            };
        };
        app.get("/my-ip") {
            app.ok(app.client_ip());
        };
        app.get("/rl-tcp") {
            app.rate_limit_key("tcp-k", 2, 60);
            if !app.handled {
                app.ok("allowed");
            }
        };
    };

    // 128 KiB response with shrunk SO_SNDBUF (16 KiB) for SIGTERM drain test.
    app.get("/bigstream") {
        honk_shrink_sndbuf(app.fd);
        for _ in 8192 {
            app.res.append("0123456789ABCDEF");
        }
        app.ok(app.res[..]);
    };
}

fn main() {
    let port = honk::arg_port(18430);
    var explicit_workers: i32 = -1;
    let a = args();
    if a.len > 2 {
        let v, ok = parse_int(a[2]);
        if ok { explicit_workers = v as! i32; }
    }
    print("app_dsl listening on port ", port);
    flush_stdout();
    if explicit_workers >= 0 {
        honk::listen_workers(port, explicit_workers) { app =>
            dsl_routes(app);
        };
    } else {
        honk::listen(port) { app =>
            dsl_routes(app);
        };
    }
}

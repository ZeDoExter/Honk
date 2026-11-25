// test/app_dsl.goose -- exercises every honk_app DSL helper, SIGINT/SIGTERM
// graceful outbound drain, and HONK_WORKERS / listen_workers fork scaling.
// Usage: ./app_dsl [port] [explicit_workers]

import std;
import os;
import honk from "../src";

inline fn dsl_routes(app: honk::Ctx&) {
    app.get("/", "dsl root");
    app.get_text("/txt", "plain literal");
    app.get_json_raw("/jraw", "{\"raw\":1}");

    // First-match-wins: second handler on the same method+path must not run.
    app.get("/first", "winner");
    app.get("/first", "loser");

    app.get("/wid") {
        app.json() { j =>
            j.int("worker", honk_worker_id() as! i64);
        };
    };

    app.get("/jtypes") {
        app.json() { j =>
            j.str("s", "a\"b");
            j.int("i", -9);
            j.jbool("b", true);
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
                j.str("s", s);
                j.int("n", n);
                j.jbool("b", b);
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

    app.get_param("/p/:slug") { slug =>
        app.ok(slug);
    };

    app.get_int("/i/:id") { id =>
        app.json() { j => j.int("id", id); };
    };
    app.patch_int("/i/:id") { id =>
        app.json() { j => j.int("patched", id); };
    };
    app.delete_int("/i/:id") { id =>
        app.json() { j => j.int("deleted", id); };
    };

    app.get2("/orgs/:org/repos/:repo") { org, repo =>
        app.json() { j =>
            j.str("org", org);
            j.str("repo", repo);
        };
    };

    app.get_wild("/w/*") { rest =>
        app.ok(rest);
    };
    app.patch_wild("/pw/") { rest =>
        app.ok(rest);
    };

    // 128 KiB response with shrunk SO_SNDBUF (16 KiB) so SIGTERM mid-flight
    // exercises multi-round EPOLLOUT outbound drain within the 2s budget.
    app.get("/bigstream") {
        honk_shrink_sndbuf(app.fd);
        for _ in 8192 {
            app.res.append("0123456789ABCDEF");
        }
        app.ok(app.res[..]);
    };
}

fn main() {
    var port: i32 = 18430;
    var explicit_workers: i32 = -1;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
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

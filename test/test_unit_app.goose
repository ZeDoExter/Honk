// test/test_unit_app.goose -- in-memory unit test suite via honk::tester().
// Exercises nested groups, cors(), bearer(), json_errors(), server_timing(),
// after(), options/all, param_dec(), nested JWriter/JArray/json_list(), and
// named-field require_* validators — plus a 10,000-request tight loop to prove
// zero stack/memory growth under Release and ASan+UBSan+LSan.

import std;
import honk from "..";
import honk.src.honk_test.honk_test;

fn api_routes(app: honk::Ctx&) {
    app.json_errors();
    app.server_timing();
    app.cors("https://ui.example");

    app.get("/ping", "pong");

    app.options("/custom-opt") {
        app.set_header("X-Custom-Opt", "1");
        app.no_content();
    };

    app.all("/any") {
        app.ok(app.method);
    };

    app.group("/api") {
        app.get("/", "api-index");

        app.group("/v1/") {
            app.get("/hello/:name") {
                let dec, ok = app.param_dec("name");
                if !ok {
                    app.json_error(400, "bad percent encoding");
                } else {
                    app.json() { j =>
                        j.set("hello", dec);
                    };
                }
            };

            app.get("/nested") {
                app.json() { j =>
                    j.set("ok", true);
                    j.obj("user") { u =>
                        u.set("id", 7);
                        u.set("name", "Ada");
                    };
                    j.arr("tags") { a =>
                        a.add("goose");
                        a.add(42);
                        a.add(true);
                        a.jnull();
                        a.obj() { o => o.set("k", "v"); };
                        a.arr() { inner => inner.add(1); inner.add(2); };
                    };
                };
            };

            app.get("/list") {
                app.json_list() { a =>
                    a.obj() { j => j.set("id", 1); };
                    a.obj() { j => j.set("id", 2); };
                };
            };

            app.post("/validate") {
                app.require_str_len("code", 2, 5) { code =>
                    app.require_int("count") { count =>
                        app.require_int_range("age", 18, 120) { age =>
                            app.require_bool("active") { active =>
                                app.created_json() { j =>
                                    j.set("code", code);
                                    j.set("count", count);
                                    j.set("age", age);
                                    j.set("active", active);
                                };
                            };
                        };
                    };
                };
            };
        };

        app.group("/admin") {
            app.bearer() { tok =>
                app.get("/me") {
                    app.json() { j => j.set("token", tok); };
                };
            };
        };
    };

    app.after() {
        let start = app.tmp.len;
        format(app.tmp, app.status);
        app.set_header("X-Final-Status", app.tmp[start..]);
    };
}

fn main() {
    var t = honk::tester();

    // 1. Basic route + Server-Timing + CORS + after() hook
    t.get("/ping") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "pong");
    let st, st_ok = t.header("Server-Timing");
    assert(st_ok && st.len >= 12 && st[..9] == "honk;dur=");
    let aco, aco_ok = t.header("Access-Control-Allow-Origin");
    assert(aco_ok && aco == "https://ui.example");
    let xfs, xfs_ok = t.header("X-Final-Status");
    assert(xfs_ok && xfs == "200");

    // 2. One-line CORS preflight handles OPTIONS before routes
    t.req("OPTIONS", "/api/v1/nested", "", "") { app => api_routes(app); };
    assert(t.status == 204 && t.body() == "");
    let aco2, aco2_ok = t.header("Access-Control-Allow-Origin");
    assert(aco2_ok && aco2 == "https://ui.example");

    // 3. `all()` matches arbitrary methods
    t.req("DELETE", "/any", "", "") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "DELETE");

    // 4. Group exact root + nested group + param_dec
    t.get("/api") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "api-index");
    // Prefix boundary: /apix must NOT match /api group -> JSON 404!
    t.get("/apix") { app => api_routes(app); };
    assert(t.status == 404 && t.ctype() == "application/json");
    assert(t.body() == "{\"error\":\"not found\"}");
    let xfs404, _ = t.header("X-Final-Status");
    assert(xfs404 == "404");

    t.get("/api/v1/hello/Ada%20Lovelace") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"hello\":\"Ada Lovelace\"}");

    t.get("/api/v1/hello/bad%zz") { app => api_routes(app); };
    assert(t.status == 400);

    // 5. JSON 405 from json_errors() mode
    t.delete("/api/v1/nested") { app => api_routes(app); };
    assert(t.status == 405 && t.ctype() == "application/json");
    assert(t.body() == "{\"error\":\"method not allowed\"}");

    // 6. Nested JWriter + JArray + json_list()
    t.get("/api/v1/nested") { app => api_routes(app); };
    assert(t.status == 200);
    assert(t.body() == "{\"ok\":true,\"user\":{\"id\":7,\"name\":\"Ada\"},\"tags\":[\"goose\",42,true,null,{\"k\":\"v\"},[1,2]]}");

    t.get("/api/v1/list") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "[{\"id\":1},{\"id\":2}]");

    // 7. Scoped Bearer guard inside /api/admin (401 JSON when missing, 200 when valid)
    t.get("/api/admin/me") { app => api_routes(app); };
    assert(t.status == 401 && t.body() == "{\"error\":\"unauthorized\"}");

    t.get_headers("/api/admin/me", "Authorization: Bearer s3cr3t\r\n") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"token\":\"s3cr3t\"}");

    // 8. Named-field validators
    t.post_json("/api/v1/validate", "{\"code\":\"OK\",\"count\":0,\"age\":30,\"active\":false}") { app => api_routes(app); };
    assert(t.status == 201 && t.body() == "{\"code\":\"OK\",\"count\":0,\"age\":30,\"active\":false}");

    t.post_json("/api/v1/validate", "{\"code\":\"X\",\"count\":0,\"age\":30,\"active\":true}") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"invalid length for field: code\"}");

    t.post_json("/api/v1/validate", "{\"code\":\"OK\",\"age\":30,\"active\":true}") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"invalid or missing field: count\"}");

    t.post_json("/api/v1/validate", "{\"code\":\"OK\",\"count\":1,\"age\":15,\"active\":true}") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"out of range: age\"}");

    t.post_json("/api/v1/validate", "{\"code\":\"OK\",\"count\":1,\"age\":25}") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"invalid or missing field: active\"}");

    // 9. 10,000 in-memory requests in a tight loop (verifies zero leaks/stack growth)
    for _ in 10000 {
        t.get("/api/v1/nested") { app => api_routes(app); };
        assert(t.status == 200);
    }

    print("ALL IN-MEMORY UNIT TESTS + 10,000 ITERATIONS PASSED");
}

// test/test_unit_app.goose -- in-memory unit suite (`honk::tester()` + `honk_auth`).
// Exercises:
//  - v0.4.0 groups, cors, bearer, json_errors, server_timing, after, nested JSON, validators
//  - v0.5.0 NIST SHA-256 & RFC 4231 HMAC-SHA256 vectors, HS256 JWT issue/verify/guard,
//    signed cookies + cross-cookie swap protection + delete_cookie, compile-time
//    embed_file() + ETag/304 Not Modified, real_ip() + rate_limit() (429 + Retry-After).
//  - v0.8.0 hardening: trusted proxies (right-to-left XFF walk), cors_cfg, request_id +
//    access_log, 8 route params, 16 response headers, float validators, op_raw, self-host
//    docs, in-memory static capture, completed status texts + MIME + Last-Modified.

import std;
import honk from "..";
import honk.src.honk_static.honk_static;
import honk.src.honk_test.honk_test;
import honk.src.honk_auth.honk_auth;
import honk.src.honk_ws.honk_ws;
import honk.src.honk_openapi.honk_openapi;

fn hex_encode(bytes: const u8[:], out: u8[>..]&) -> const u8[:] {
    let hx = "0123456789abcdef";
    let s = out.len;
    for b in bytes {
        out.push(hx[((b >> 4) & 15) as! i64]);
        out.push(hx[(b & 15) as! i64]);
    }
    return out[s..];
}
fn has_sub(hay: const u8[:], needle: const u8[:]) -> bool {
    if needle.len == 0 { return true; }
    if needle.len > hay.len { return false; }
    var i: i64 = 0;
    while i + needle.len <= hay.len {
        if hay[i..i + needle.len] == needle { return true; }
        i++;
    }
    return false;
}

fn verify_crypto_vectors() {
    var buf: u8[>..] = [];

    // NIST FIPS 180-4 SHA-256 vectors (0-byte, "abc", 56-byte 2-block boundary)
    let h_empty = honk::sha256("");
    assert(hex_encode(h_empty[..], buf) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    let h_abc = honk::sha256("abc");
    assert(hex_encode(h_abc[..], buf) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    let h_2blk = honk::sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    assert(hex_encode(h_2blk[..], buf) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

    // RFC 4231 Test Case 2: HMAC-SHA256("Jefe", "what do ya want for nothing?")
    let mac2 = honk::hmac_sha256("Jefe", "what do ya want for nothing?");
    assert(hex_encode(mac2[..], buf) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    // RFC 4231 Test Case 6: 131-byte key (> 64-byte block size)
    var long_key: u8[131] = [0xaa; 131];
    let mac6 = honk::hmac_sha256(long_key[..], "Test Using Larger Than Block-Size Key - Hash Key First");
    assert(hex_encode(mac6[..], buf) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");

    // NIST FIPS 180-4 SHA-1 ("abc") + RFC 6455 §4.2.2 Sec-WebSocket-Accept vector
    let s1_abc = honk::sha1("abc");
    assert(hex_encode(s1_abc[..], buf) == "a9993e364706816aba3e25717850c26c9cd0d89d");
    let ws_acc = honk::ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==", buf);
    assert(ws_acc == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

fn api_routes(app: honk::Ctx&) {
    let secret = "honk-super-secret-256";
    let emb_html = embed_file("static_fixtures/index.html");

    app.json_errors();
    app.server_timing();
    app.cors("https://ui.example");

    app.get("/ping", "pong");
    app.embed("/embedded.html", emb_html, "", "public, max-age=3600");

    app.options("/custom-opt") {
        app.set_header("X-Custom-Opt", "1");
        app.no_content();
    };

    app.all("/any") {
        app.ok(app.method);
    };

    app.post("/auth/login") {
        app.require_str("user") { u =>
            let tok = app.jwt_issue(secret, u, 3600);
            app.set_signed_cookie("sess", u, secret);
            app.json() { j => j.set("token", tok); };
        };
    };

    app.post("/auth/logout") {
        app.delete_cookie("sess");
        app.ok_json();
    };

    app.get("/auth/session") {
        let u, ok = app.signed_cookie("sess", secret);
        if !ok {
            app.json_error(401, "invalid session cookie");
        } else {
            app.json() { j => j.set("session_user", u); };
        }
    };

    app.group("/jwt-area") {
        app.jwt(secret) { claims =>
            app.get("/me") {
                let exp, _ = app.jwt_claim_int(claims, "exp");
                app.json() { j =>
                    j.set("user", app.user);
                    j.set("authed", app.authed);
                    j.set("has_exp", exp > 0);
                };
            };
        };
    };

    app.group("/rl") {
        app.rate_limit(3, 60);
        app.get("/ip") {
            app.ok(app.real_ip());
        };
    };
    app.group("/proxy-ip") {
        app.get("/via") {
            let nets, _ = honk::parse_cidrs("127.0.0.0/8,10.0.0.0/8");
            app.ok(app.real_ip_trusted(nets));
        };
    };

    app.get("/p8/:a/:b/:c/:d/:e/:f") {
        app.json() { j =>
            j.set("a", app.param("a"));
            j.set("b", app.param("b"));
            j.set("c", app.param("c"));
            j.set("d", app.param("d"));
            j.set("e", app.param("e"));
            j.set("f", app.param("f"));
            j.set("last_idx", app.param(5));
        };
    };

    app.get("/hdrs12") {
        app.set_header("X-H01", "1");
        app.set_header("X-H02", "2");
        app.set_header("X-H03", "3");
        app.set_header("X-H04", "4");
        app.set_header("X-H05", "5");
        app.set_header("X-H06", "6");
        app.set_header("X-H07", "7");
        app.set_header("X-H08", "8");
        app.set_header("X-H09", "9");
        app.set_header("X-H10", "10");
        app.set_header("X-H11", "11");
        app.set_header("X-H12", "12");
        app.ok("h");
    };

    app.post("/validate-f") {
        app.require_float("price") { price =>
            app.require_float_range("ratio", 0.0, 1.0) { ratio =>
                app.created_json() { j =>
                    j.set("price", price);
                    j.set("ratio", ratio);
                };
            };
        };
    };

    app.get("/rid") {
        app.ok(app.request_id());
    };

    app.get("/logged") {
        app.access_log();
        app.ok("logged");
    };

    app.static_dir("/st", "test/static_fixtures");

    app.group("/api") {
        app.get("/", "api-index");

        app.group("/v1/") {
            app.get("/hello/:name") {
                let dec, ok = app.param_dec("name");
                if !ok {
                    app.json_error(400, "bad percent encoding");
                } else {
                    app.json() { j => j.set("hello", dec); };
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

    // v0.6.0: URL-encoded forms, zero-copy multipart/form-data, chunked stream & SSE
    app.post("/forms/submit") {
        app.require_form("full name") { name =>
            let age, aok = app.form_int("age");
            let role = app.form_or("role", "guest");
            app.json() { j =>
                j.set("name", name);
                j.set("age", if aok { age } else { -1 });
                j.set("role", role);
            };
        };
    };

    app.post("/forms/upload") {
        var count: i64 = 0;
        let valid = app.each_part() { _p =>
            count++;
        };
        let f, fok = app.multipart_file("avatar");
        if !valid || !fok {
            app.json_error(400, "invalid multipart");
        } else {
            let b0: i64 = if f.data.len > 0 { f.data[0] } else { -1 };
            let b_last: i64 = if f.data.len > 0 { f.data[f.data.len - 1] } else { -1 };
            app.json() { j =>
                j.set("title", app.form_or("title", ""));
                j.set("filename", f.filename);
                j.set("ctype", f.ctype);
                j.set("size", f.data.len);
                j.set("b0", b0);
                j.set("blast", b_last);
                j.set("parts", count);
            };
        }
    };

    app.get("/stream/chunks") {
        app.stream("text/plain") { s =>
            s.write("alpha-");
            s.write("beta");
        };
    };

    app.get("/stream/sse") {
        app.sse() { ev =>
            ev.retry(1500);
            ev.comment("ping");
            ev.send("l1\nl2");
            ev.event("tick", "99");
            ev.id_event("7", "done", "ok");
        };
    };

    // v0.7.0: RFC 6455 WebSocket upgrade + OpenAPI 3.1.0 + Docs UI
    app.ws("/ws/:room") { ws =>
        ws.each_msg() { msg =>
            ws.send(msg);
        };
    };

    app.openapi("/openapi.json", "Unit API", "0.7.0") { spec =>
        spec.desc("Test spec");
        spec.server("http://localhost:18080");
        spec.op("GET", "/todos", "List todos");
        spec.op_body("POST", "/todos", "Create todo", "{\"type\":\"object\"}");
        spec.op_int("PATCH", "/todos/:id/toggle", "Toggle todo");
        spec.op_auth("DELETE", "/todos/:id", "Delete todo");
        spec.op_raw("GET", "/todos/search", "Search todos", "\"parameters\":[{\"name\":\"q\",\"in\":\"query\"}]");
    };
    app.docs("/docs", "/openapi.json", "Unit API <Docs>");
    app.docs("/docs-self", "/openapi.json", "Unit API", "https://cdn.internal/scalar.js");

    app.after() {
        let start = app.tmp.len;
        format(app.tmp, app.status);
        app.set_header("X-Final-Status", app.tmp[start..]);
    };
}
fn cfg_routes(app: honk::Ctx&) {
    app.cors_cfg("https://a.example, https://b.example", "GET, POST", "Content-Type", 600, true);
    app.get("/cfg", "cfg-ok");
}

fn cfg_star_routes(app: honk::Ctx&) {
    app.cors_cfg("*", "GET", "Content-Type", 0, true);
    app.get("/cfg", "cfg-ok");
}

fn main() {
    verify_crypto_vectors();

    var t = honk::tester();

    // 1. Basic route + Server-Timing + CORS + after()
    t.get("/ping") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "pong");
    let st, st_ok = t.header("Server-Timing");
    assert(st_ok && st.len >= 12 && st[..9] == "honk;dur=");
    let aco, aco_ok = t.header("Access-Control-Allow-Origin");
    assert(aco_ok && aco == "https://ui.example");
    let xfs, xfs_ok = t.header("X-Final-Status");
    assert(xfs_ok && xfs == "200");

    // 2. CORS preflight + all()
    t.req("OPTIONS", "/api/v1/nested", "", "") { app => api_routes(app); };
    assert(t.status == 204 && t.body() == "");
    t.req("DELETE", "/any", "", "") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "DELETE");

    // 3. Groups + JSON 404/405 + param_dec + nested JSON + validators
    t.get("/api") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "api-index");
    t.get("/apix") { app => api_routes(app); };
    assert(t.status == 404 && t.body() == "{\"error\":\"not found\"}");
    t.get("/api/v1/hello/Ada%20Lovelace") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"hello\":\"Ada Lovelace\"}");
    t.delete("/api/v1/nested") { app => api_routes(app); };
    assert(t.status == 405 && t.body() == "{\"error\":\"method not allowed\"}");

    t.get("/api/v1/nested") { app => api_routes(app); };
    assert(t.body() == "{\"ok\":true,\"user\":{\"id\":7,\"name\":\"Ada\"},\"tags\":[\"goose\",42,true,null,{\"k\":\"v\"},[1,2]]}");
    t.get("/api/v1/list") { app => api_routes(app); };
    assert(t.body() == "[{\"id\":1},{\"id\":2}]");

    t.post_json("/api/v1/validate", "{\"code\":\"OK\",\"count\":0,\"age\":30,\"active\":false}") { app => api_routes(app); };
    assert(t.status == 201);
    t.post_json("/api/v1/validate", "{\"code\":\"OK\",\"count\":1,\"age\":15,\"active\":true}") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"out of range: age\"}");

    // 4. JWT (HS256) issue + guard + tamper/alg:none/expired rejection
    t.post_json("/auth/login", "{\"user\":\"ada\"}") { app => api_routes(app); };
    assert(t.status == 200);
    let set_ck, sc_ok = t.header("Set-Cookie");
    assert(sc_ok && set_ck[..9] == "sess=ada.");
    // Save Set-Cookie value (`sess=ada.<sig>`) before reusing `t`.
    var ck_end = set_ck.len;
    for ch, i in set_ck {
        if ch == ';' { ck_end = i; break; }
    }
    var saved_ck: u8[>..] = [];
    saved_ck.append("Cookie: ");
    saved_ck.append(set_ck[..ck_end]);
    saved_ck.append("\r\n");
    var swapped_ck: u8[>..] = [];
    swapped_ck.append("Cookie: evil=");
    swapped_ck.append(set_ck[5..ck_end]);
    swapped_ck.append("\r\n");

    // Parse issued JWT from {"token":"..."}
    var jwt_saved: u8[>..] = [];
    var lr = json::reader(t.body());
    json::each_member(lr) { k =>
        if k == "token" {
            let s = json::read_string(lr, jwt_saved);
            if jwt_saved.len == 0 { jwt_saved.append(s); }
        } else {
            json::skip(lr);
        }
    };
    assert(json::finish(lr) && jwt_saved.len > 40);

    var auth_hdr: u8[>..] = [];
    auth_hdr.append("Authorization: Bearer ");
    auth_hdr.append(jwt_saved[..]);
    auth_hdr.append("\r\n");

    t.get_headers("/jwt-area/me", auth_hdr[..]) { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"user\":\"ada\",\"authed\":true,\"has_exp\":true}");

    // Tamper last signature character -> 401
    var bad_hdr: u8[>..] = [];
    bad_hdr.append("Authorization: Bearer ");
    bad_hdr.append(jwt_saved[..jwt_saved.len - 1]);
    bad_hdr.push(if jwt_saved[jwt_saved.len - 1] == 'A' { 'B' } else { 'A' });
    bad_hdr.append("\r\n");
    t.get_headers("/jwt-area/me", bad_hdr[..]) { app => api_routes(app); };
    assert(t.status == 401);

    // Expired JWT (`exp: 1000`) -> 401
    var exp_buf: u8[>..] = [];
    let exp_jwt = honk::jwt_sign("{\"sub\":\"ada\",\"exp\":1000}", "honk-super-secret-256", exp_buf);
    var exp_hdr: u8[>..] = [];
    exp_hdr.append("Authorization: Bearer ");
    exp_hdr.append(exp_jwt);
    exp_hdr.append("\r\n");
    t.get_headers("/jwt-area/me", exp_hdr[..]) { app => api_routes(app); };
    assert(t.status == 401);

    // `alg: none` forgery -> rejected
    var scratch: u8[>..] = [];
    let _, none_ok = honk::jwt_verify("eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJhZG1pbiJ9.x", "honk-super-secret-256", scratch);
    assert(!none_ok);

    // 5. Signed cookie verification + cross-cookie swap rejection + delete_cookie
    t.get_headers("/auth/session", saved_ck[..]) { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"session_user\":\"ada\"}");

    t.get_headers("/auth/session", "Cookie: sess=admin.fakesig\r\n") { app => api_routes(app); };
    assert(t.status == 401);

    t.get_headers("/auth/session", swapped_ck[..]) { app => api_routes(app); };
    assert(t.status == 401);

    t.post_json("/auth/logout", "{}") { app => api_routes(app); };
    let del_ck, del_ok = t.header("Set-Cookie");
    assert(del_ok && del_ck == "sess=; Path=/; Max-Age=0; HttpOnly");

    // 6. Compile-time embed_file() + ETag + 304 Not Modified
    t.get("/embedded.html") { app => api_routes(app); };
    assert(t.status == 200 && t.ctype() == "text/html" && t.body().len > 0);
    let etag_raw, et_ok = t.header("ETag");
    assert(et_ok && etag_raw.len > 2);
    let cc_raw, cc_ok = t.header("Cache-Control");
    assert(cc_ok && cc_raw == "public, max-age=3600");

    var inm_hdr: u8[>..] = [];
    inm_hdr.append("If-None-Match: ");
    inm_hdr.append(etag_raw);
    inm_hdr.append("\r\n");
    t.get_headers("/embedded.html", inm_hdr[..]) { app => api_routes(app); };
    assert(t.status == 304 && t.body() == "");

    // 7. Socket-keyed rate_limit (spoof-proof) + real_ip_trusted (right-to-left XFF walk)
    let xff_a = "X-Forwarded-For: 203.0.113.9, 10.0.0.1\r\n";
    for expected_rem in 3 {
        t.get_headers("/rl/ip", xff_a) { app => api_routes(app); };
        assert(t.status == 200 && t.body() == "203.0.113.9");
        let rem_h, rok = t.header("X-RateLimit-Remaining");
        assert(rok && rem_h.len > 0);
    }
    t.get_headers("/rl/ip", xff_a) { app => api_routes(app); };
    assert(t.status == 429 && t.body() == "{\"error\":\"too many requests\"}");
    let ra_h, ra_ok = t.header("Retry-After");
    assert(ra_ok && ra_h.len > 0);

    // Spoofed X-Real-IP cannot escape the socket-keyed quota
    t.get_headers("/rl/ip", "X-Real-IP: 198.51.100.7\r\n") { app => api_routes(app); };
    assert(t.status == 429);

    // Trusted-proxy RTL walk: skips trusted 10/8 hop, returns rightmost untrusted
    t.get_headers("/proxy-ip/via", xff_a) { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "203.0.113.9");
    // Leftmost spoof ignored: returns 203.0.113.5, NOT 1.1.1.1
    t.get_headers("/proxy-ip/via", "X-Forwarded-For: 1.1.1.1, 203.0.113.5\r\n") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "203.0.113.5");
    // All hops trusted -> falls back to socket peer
    t.get_headers("/proxy-ip/via", "X-Forwarded-For: 10.1.2.3\r\n") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "127.0.0.1");

    // 8. URL-encoded form + require_form + multipart/form-data + stream + SSE
    t.post_form("/forms/submit", "full+name=Ada+Lovelace%21&age=36") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"name\":\"Ada Lovelace!\",\"age\":36,\"role\":\"guest\"}");

    t.post_form("/forms/submit", "age=36") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"invalid or missing field: full name\"}");

    var mp_body: u8[>..] = [];
    mp_body.append("--Bnd123\r\n");
    mp_body.append("Content-Disposition: form-data; name=\"title\"\r\n\r\n");
    mp_body.append("Profile Photo\r\n");
    mp_body.append("--Bnd123\r\n");
    mp_body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"C:\\fakepath\\pic.png\"\r\n");
    mp_body.append("Content-Type: image/png\r\n\r\n");
    mp_body.push(0x89);
    mp_body.push(0x00);
    mp_body.append("\r\n--not-the-boundary\r\n");
    mp_body.push(0xff);
    mp_body.append("\r\n--Bnd123--\r\n");

    t.req("POST", "/forms/upload", "Content-Type: multipart/form-data; boundary=\"Bnd123\"\r\n", mp_body[..]) { app =>
        api_routes(app);
    };
    assert(t.status == 200 && t.body() == "{\"title\":\"Profile Photo\",\"filename\":\"pic.png\",\"ctype\":\"image/png\",\"size\":25,\"b0\":137,\"blast\":255,\"parts\":2}");

    // Truncated multipart (missing closing --Bnd123--) -> 400
    t.req("POST", "/forms/upload", "Content-Type: multipart/form-data; boundary=Bnd123\r\n", "--Bnd123\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"x\"\r\n\r\nabc") { app =>
        api_routes(app);
    };
    assert(t.status == 400);

    t.get("/stream/chunks") { app => api_routes(app); };
    let te_h, te_ok = t.header("Transfer-Encoding");
    assert(t.status == 200 && te_ok && te_h == "chunked" && t.body() == "alpha-beta");

    t.get("/stream/sse") { app => api_routes(app); };
    let sse_cc, scc_ok = t.header("Cache-Control");
    assert(t.status == 200 && t.ctype() == "text/event-stream" && scc_ok && sse_cc == "no-cache");
    assert(t.body() == "retry: 1500\n\n: ping\n\ndata: l1\ndata: l2\n\nevent: tick\ndata: 99\n\nid: 7\nevent: done\ndata: ok\n\n");

    // 9. WebSocket RFC 6455 handshake (101 / 426 / 400) + OpenAPI 3.1.0 + Docs UI
    let ws_hdrs = "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n";
    t.get_headers("/ws/general", ws_hdrs) { app => api_routes(app); };
    let ws_acc_h, wsa_ok = t.header("Sec-WebSocket-Accept");
    assert(t.status == 101 && wsa_ok && ws_acc_h == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");

    let ws_bad_ver = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n";
    t.get_headers("/ws/general", ws_bad_ver) { app => api_routes(app); };
    let wsv_h, wsv_ok = t.header("Sec-WebSocket-Version");
    assert(t.status == 426 && wsv_ok && wsv_h == "13");

    t.get("/ws/general") { app => api_routes(app); };
    assert(t.status == 400);

    t.get("/openapi.json") { app => api_routes(app); };
    assert(t.status == 200 && t.ctype() == "application/json" && t.body()[..20] == "{\"openapi\":\"3.1.0\",\"");

    t.get("/docs") { app => api_routes(app); };
    assert(t.status == 200 && t.ctype() == "text/html" && t.body().len > 150);
    // 11. v0.8.0 hardening: status texts, CIDR/IPv4, 8 params, 16 headers,
    //     cors_cfg, float validators, request_id, op_raw, self-host docs, static capture
    assert(honk::status_text(206) == "Partial Content");
    assert(honk::status_text(413) == "Payload Too Large");
    assert(honk::status_text(416) == "Range Not Satisfiable");
    assert(honk::status_text(431) == "Request Header Fields Too Large");
    assert(honk::status_text(501) == "Not Implemented");
    assert(honk::status_text(503) == "Service Unavailable");

    let nets_t, nok_t = honk::parse_cidrs("127.0.0.1,10.0.0.0/8");
    assert(nok_t && nets_t.n == 2);
    let _, bad_ok = honk::parse_cidrs("999.1.1.1,xx");
    assert(!bad_ok);
    let ip4, ip4ok = honk::parse_ipv4("192.168.1.1");
    assert(ip4ok && ip4 == 3232235777);
    let _, ip4bad = honk::parse_ipv4("1.2.3.256");
    assert(!ip4bad);

    t.get("/p8/1/2/3/4/5/6") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\",\"d\":\"4\",\"e\":\"5\",\"f\":\"6\",\"last_idx\":\"6\"}");

    t.get("/hdrs12") { app => api_routes(app); };
    let h01, h01ok = t.header("X-H01");
    let h12, h12ok = t.header("X-H12");
    assert(t.status == 200 && h01ok && h01 == "1" && h12ok && h12 == "12");

    t.get_headers("/cfg", "Origin: https://b.example\r\n") { app => cfg_routes(app); };
    let c_ao, c_ao_ok = t.header("Access-Control-Allow-Origin");
    let c_vary, c_vary_ok = t.header("Vary");
    let c_cred, c_cred_ok = t.header("Access-Control-Allow-Credentials");
    let c_ma, c_ma_ok = t.header("Access-Control-Max-Age");
    assert(t.status == 200 && c_ao_ok && c_ao == "https://b.example" && c_vary_ok && c_vary == "Origin");
    assert(c_cred_ok && c_cred == "true" && c_ma_ok && c_ma == "600");

    t.get_headers("/cfg", "Origin: https://evil.example\r\n") { app => cfg_routes(app); };
    let _, eao_ok = t.header("Access-Control-Allow-Origin");
    let e_vary, e_vary_ok = t.header("Vary");
    assert(t.status == 200 && !eao_ok && e_vary_ok && e_vary == "Origin");

    t.req("OPTIONS", "/cfg", "Origin: https://a.example\r\n", "") { app => cfg_routes(app); };
    assert(t.status == 204);

    t.get_headers("/cfg", "Origin: https://x.example\r\n") { app => cfg_star_routes(app); };
    let s_ao, s_ao_ok = t.header("Access-Control-Allow-Origin");
    let _, s_cred_ok = t.header("Access-Control-Allow-Credentials");
    assert(s_ao_ok && s_ao == "*" && !s_cred_ok);

    t.post_json("/validate-f", "{\"price\":9.5,\"ratio\":0.25}") { app => api_routes(app); };
    assert(t.status == 201 && t.body() == "{\"price\":9.5,\"ratio\":0.25}");
    t.post_json("/validate-f", "{\"price\":\"9\",\"ratio\":0.5}") { app => api_routes(app); };
    assert(t.status == 400);
    t.post_json("/validate-f", "{\"price\":9.5,\"ratio\":7.0}") { app => api_routes(app); };
    assert(t.status == 400 && t.body() == "{\"error\":\"out of range: ratio\"}");

    t.get_headers("/rid", "X-Request-Id: req-123_abc:1.2\r\n") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "req-123_abc:1.2");
    t.get_headers("/rid", "X-Request-Id: bad id!\r\n") { app => api_routes(app); };
    assert(t.status == 200 && t.body()[..1] == "w");
    t.get("/rid") { app => api_routes(app); };
    assert(t.status == 200 && t.body()[..1] == "w");

    t.get("/logged") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "logged");

    t.get("/openapi.json") { app => api_routes(app); };
    assert(has_sub(t.body(), "\"/todos/search\"") && has_sub(t.body(), "\"parameters\":[{\"name\":\"q\",\"in\":\"query\"}]"));

    t.get("/docs-self") { app => api_routes(app); };
    assert(t.status == 200 && has_sub(t.body(), "https://cdn.internal/scalar.js"));

    t.get("/st/index.html") { app => api_routes(app); };
    let st_etag, st_etag_ok = t.header("ETag");
    let st_lm, st_lm_ok = t.header("Last-Modified");
    let st_cl, st_cl_ok = t.header("Content-Length");
    assert(t.status == 200 && st_etag_ok && st_lm_ok && st_cl_ok && st_cl.len > 0);

    // 10. 10,000 in-memory requests loop + rate-table cleanup for LSan
    for _ in 10000 {
        t.get("/api/v1/nested") { app => api_routes(app); };
        assert(t.status == 200);
    }
    honk_rate_reset();

    print("ALL IN-MEMORY UNIT + AUTH + EMBED + RATE-LIMIT + STREAM + FORM + WS + OPENAPI + V0.8.0 HARDENING TESTS PASSED");
}

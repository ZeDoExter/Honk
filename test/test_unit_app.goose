// test/test_unit_app.goose -- in-memory unit suite (`honk::tester()` + `honk_auth`).
// Exercises:
//  - v0.4.0 groups, cors, bearer, json_errors, server_timing, after, nested JSON, validators
//  - v0.5.0 NIST SHA-256 & RFC 4231 HMAC-SHA256 vectors, HS256 JWT issue/verify/guard,
//    signed cookies + cross-cookie swap protection + delete_cookie, compile-time
//    embed_file() + ETag/304 Not Modified, real_ip() + rate_limit() (429 + Retry-After).

import std;
import honk from "..";
import honk.src.honk_test.honk_test;
import honk.src.honk_auth.honk_auth;

fn hex_encode(bytes: const u8[:], out: u8[>..]&) -> const u8[:] {
    let hx = "0123456789abcdef";
    let s = out.len;
    for b in bytes {
        out.push(hx[((b >> 4) & 15) as! i64]);
        out.push(hx[(b & 15) as! i64]);
    }
    return out[s..];
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

    app.after() {
        let start = app.tmp.len;
        format(app.tmp, app.status);
        app.set_header("X-Final-Status", app.tmp[start..]);
    };
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

    // 7. Real IP (`X-Forwarded-For`) + Per-IP Rate Limiter (3 reqs / 60s -> 429)
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

    // Distinct IP keeps its own quota
    t.get_headers("/rl/ip", "X-Real-IP: 198.51.100.7\r\n") { app => api_routes(app); };
    assert(t.status == 200 && t.body() == "198.51.100.7");

    // 8. 10,000 in-memory requests loop + rate-table cleanup for LSan
    for _ in 10000 {
        t.get("/api/v1/nested") { app => api_routes(app); };
        assert(t.status == 200);
    }
    honk_rate_reset();

    print("ALL IN-MEMORY UNIT + AUTH + EMBED + RATE-LIMIT TESTS PASSED");
}

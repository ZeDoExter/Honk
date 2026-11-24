// test/helpers_app.goose -- exercises every web helper for test_web.py.
// Served via the public honk::serve API (also dogfoods it under ASan).
// NOTE: blocks are inlined: never `return`/`break` inside them; use if/else.

import std;
import os;
import json;
import honk_net from "../src/honk_net";
import honk_ctx from "../src/honk_ctx";
import honk_serve from "../src/honk_serve";

thread_fn worker(port: i32) {
    honk::listen_or_abort(port);
    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.method == "OPTIONS" {
                ctx.cors_preflight();
            } else if ctx.method == "GET" {
                let ps, pok = match_1param(ctx.path, "/p/str/");
                if pok {
                    ctx.params[0] = ps;
                    ctx.n_params = 1;
                    ctx.text(200, ctx.param_str(0));
                } else {
                    let pi, piok = match_1param(ctx.path, "/p/int/");
                    if piok {
                        ctx.params[0] = pi;
                        ctx.n_params = 1;
                        let n, nok = ctx.param_int(0);
                        if nok {
                            ctx.res.append("{\"v\":");
                            format(ctx.res, n);
                            ctx.res.push('}');
                            ctx.json_raw(200, ctx.res[..]);
                        } else {
                            ctx.json_error(400, "bad int");
                        }
                    } else if ctx.path == "/q/or" {
                        let name = ctx.query_str_or("name", "anon");
                        let page = ctx.query_int_or("page", 1);
                        ctx.res.append("{\"name\":");
                        json::format_string(ctx.res, name);
                        ctx.res.append(",\"page\":");
                        format(ctx.res, page);
                        ctx.res.push('}');
                        ctx.json_raw(200, ctx.res[..]);
                    } else if ctx.path == "/q/dec" {
                        let v, ok = ctx.query_decoded("x");
                        if ok {
                            ctx.text(200, v);
                        } else {
                            ctx.text(400, "Bad Request");
                        }
                    } else {
                        let pd, pdok = match_1param(ctx.path, "/p/dec/");
                        if pdok {
                            ctx.params[0] = pd;
                            ctx.n_params = 1;
                            let v, ok = ctx.param_decoded(0);
                            if ok {
                                ctx.text(200, v);
                            } else {
                                ctx.text(400, "Bad Request");
                            }
                        } else if ctx.path == "/auth/me" {
                            let tok, ok = ctx.bearer_token();
                            if ok {
                                ctx.text(200, tok);
                            } else {
                                ctx.text(401, "Unauthorized");
                            }
                        } else if ctx.path == "/cookies" {
                            let v, ok = ctx.cookie("sess");
                            if ok {
                                ctx.text(200, v);
                            } else {
                                ctx.text(404, "none");
                            }
                        } else if ctx.path == "/cookies/set" {
                            let nm = ctx.query_str_or("name", "s");
                            let vv = ctx.query_str_or("val", "v");
                            ctx.set_cookie(nm, vv, "Path=/; Max-Age=60");
                            ctx.text(200, "set");
                        } else if ctx.path == "/htmlx" {
                            ctx.html(200, "<h1>hi</h1>");
                        } else if ctx.path == "/rawx" {
                            ctx.json_raw(200, "{\"a\":[1,2]}");
                        } else if ctx.path == "/errx" {
                            ctx.json_error(422, "bad \"thing\"\\");
                        } else if ctx.path == "/nocont" {
                            ctx.no_content();
                        } else if ctx.path == "/redir" {
                            ctx.redirect("/target");
                        } else if ctx.path == "/redir301" {
                            ctx.redirect("/perm", 301);
                        } else if ctx.path == "/cors" {
                            ctx.cors_allow_all();
                            ctx.text(200, "cors-ok");
                        } else if ctx.path == "/cors-origin" {
                            ctx.cors_with_origin("https://app.example");
                            ctx.text(200, "cors-ok");
                        } else {
                            let rest, rok = ctx.rest("/files/");
                            if rok {
                                if rest.has_dotdot() {
                                    ctx.text(400, "Bad Request");
                                } else {
                                    ctx.text(200, rest);
                                }
                            }
                            // else: unstaged -> turn defaults to 404.
                        }
                    }
                }
            } else if ctx.method == "POST" && ctx.path == "/__shutdown" {
                honk_request_stop();
                ctx.keep_alive = false;
                ctx.text(200, "shutting down");
            }
        };
    };
}

fn main() {
    var port: i32 = 18080;
    let a = args();
    if a.len > 1 {
        let v, ok = parse_int(a[1]);
        if ok { port = v as! i32; }
    }
    print("helpers_app listening on port ", port);
    flush_stdout();
    let tid = thread_spawn(worker, port);
    thread_wait(tid);
}

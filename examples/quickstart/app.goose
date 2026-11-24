// examples/quickstart/app.goose -- minimal realistic Honk application.
//
// Routes, :params, ?query, middleware guard, typed JSON POST — no transport
// code: honk::serve/request own the epoll loop, buffers, emit, and shutdown.
//
// Build:  goose build examples/quickstart/app.goose -o examples/quickstart/app
// Run:    ./examples/quickstart/app [port]
// NOTE: blocks are inlined: never `return`/`break` inside them; use if/else.

import std;
import os;
import json;
import honk_net from "../../src/honk_net";
import honk_ctx from "../../src/honk_ctx";
import honk_serve from "../../src/honk_serve";

// Guard using the one-call bearer helper; decorates ctx.user.
inline fn check_auth(c: Ctx&) -> bool {
    if c.path == "/private" {
        let tok, ok = c.bearer_token();
        if !ok {
            c.text(401, "Unauthorized");
            return false;
        }
        c.user = tok;
        c.authed = true;
    }
    return true;
}

struct Signup {
    username: const u8[:],
    has_username: bool,
    email: const u8[:],
    has_email: bool,
    age: i64,
    has_age: bool,
}

fn parse_signup(r: json::Reader&, scratch: u8[>..]&, s: Signup&) -> bool {
    json::each_member(r) { key =>
        if key == "username" {
            s.username = json::read_string(r, scratch);
            s.has_username = true;
        } else if key == "email" {
            s.email = json::read_string(r, scratch);
            s.has_email = true;
        } else if key == "age" {
            s.age = json::read_int(r);
            s.has_age = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) { return false; }
    if !s.has_username || !s.has_email { return false; }
    return true;
}

thread_fn worker(port: i32) {
    honk::listen_or_abort(port);
    honk::serve() { fd, date =>
        honk::request(fd, date) { ctx =>
            if ctx.path != "/" {
                ctx.set_header("X-Example", "quickstart");
            }
            if check_auth(ctx) {
                if ctx.method == "GET" && ctx.path == "/" {
                    ctx.text(200, "Welcome to Honk! Try /hello/ada?title=Dr, /private, /signup");
                } else if ctx.method == "GET" {
                    let seg, ok = match_1param(ctx.path, "/hello/");
                    if ok {
                        let title = ctx.query_str_or("title", "");
                        ctx.res.append("Hello, ");
                        if title.len > 0 {
                            ctx.res.append(title);
                            ctx.res.push(' ');
                        }
                        ctx.res.append(seg);
                        ctx.res.push('!');
                        ctx.text(200, ctx.res[..]);
                    } else if ctx.path == "/private" {
                        ctx.res.append("hello ");
                        ctx.res.append(ctx.user);
                        ctx.res.append(", this route is guarded by middleware");
                        ctx.text(200, ctx.res[..]);
                    }
                } else if ctx.method == "POST" && ctx.path == "/signup" {
                    var s = Signup { username: "", .. };
                    var r = json::reader(ctx.body);
                    if !parse_signup(r, ctx.tmp, s) || s.username.len == 0 || s.email.len == 0 {
                        ctx.text(400, "Bad Request");
                    } else {
                        ctx.res.push('{');
                        json::format_key(ctx.res, "created");
                        json::format_bool(ctx.res, true);
                        ctx.res.push(',');
                        json::format_key(ctx.res, "username");
                        json::format_string(ctx.res, s.username);
                        if s.has_age {
                            ctx.res.push(',');
                            json::format_key(ctx.res, "age");
                            json::format_int(ctx.res, s.age);
                        }
                        ctx.res.push('}');
                        ctx.json_raw(201, ctx.res[..]);
                    }
                } else if ctx.method == "POST" && ctx.path == "/__shutdown" {
                    honk_request_stop();
                    ctx.keep_alive = false;
                    ctx.text(200, "shutting down");
                }
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
    print("quickstart listening on port ", port);
    flush_stdout();
    let tid = thread_spawn(worker, port);
    thread_wait(tid);
}

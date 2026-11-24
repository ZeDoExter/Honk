// honk_json.goose -- JSON framework helpers over stdlib/json.goose.
//
// - Typed zero-DOM binding (json::Reader) for POST /api/typed: required
//   fields (name: string, age: int), optional score (number), tags (array of
//   string, capped at 8), nested address {city, zip}; unknown keys skipped.
//   Unescaped strings stay zero-copy views into rx_buf; only escaped strings
//   decode into the per-request scratch buffer.
// - Scoped DOM inspection (json::parse) for POST /api/dom.
// - In-place serialization (json::format_*) for GET /json and echoes.
// All buffers are caller-owned per-request data-stack scopes, reclaimed at
// request scope exit. No heap allocations.

import std;
import json;

struct JsonAddr { city: const u8[:], has_city: bool, zip: i64, has_zip: bool }

struct TypedPost {
    name: const u8[:],
    has_name: bool,
    age: i64,
    has_age: bool,
    score: f64,
    has_score: bool,
    tags: const u8[:][8],
    n_tags: i64,
    addr: JsonAddr,
    has_addr: bool,
}

// Strict typed parse into caller-owned t: false on malformed JSON, trailing
// tokens, type mismatches, or missing required fields. Never aborts.
// The Reader is caller-owned (borrow §9.2: read_string views root at
// r.text, so r must outlive the parse; t's unescaped strings then root at
// the caller's body, escaped ones at the caller's scratch).
fn parse_typed_fields(r: json::Reader&, scratch: u8[>..]&, t: TypedPost&) -> bool {
    json::each_member(r) { key =>
        if key == "name" {
            t.name = json::read_string(r, scratch);
            t.has_name = true;
        } else if key == "age" {
            t.age = json::read_int(r);
            t.has_age = true;
        } else if key == "score" {
            t.score = json::read_number(r);
            t.has_score = true;
        } else if key == "tags" {
            json::each_element(r) {
                let nt = t.n_tags;
                if nt < 8 {
                    t.tags[nt] = json::read_string(r, scratch);
                    t.n_tags = nt + 1;
                } else {
                    json::skip(r);
                }
            };
        } else if key == "address" {
            t.has_addr = true;
            json::each_member(r) { k2 =>
                if k2 == "city" {
                    t.addr.city = json::read_string(r, scratch);
                    t.addr.has_city = true;
                } else if k2 == "zip" {
                    t.addr.zip = json::read_int(r);
                    t.addr.has_zip = true;
                } else {
                    json::skip(r);
                }
            };
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) { return false; }
    if !t.has_name || !t.has_age { return false; }
    return true;
}

// Serialize the validated struct back to JSON in place.
fn emit_typed_post(out: u8[>..]&, t: TypedPost&) {
    out.push('{');
    json::format_key(out, "ok");
    json::format_bool(out, true);
    out.push(',');
    json::format_key(out, "name");
    json::format_string(out, t.name);
    out.push(',');
    json::format_key(out, "age");
    json::format_int(out, t.age);
    if t.has_score {
        out.push(',');
        json::format_key(out, "score");
        json::format_number(out, t.score);
    }
    out.push(',');
    json::format_key(out, "tags");
    json::format_int(out, t.n_tags);
    if t.has_addr && t.addr.has_city {
        out.push(',');
        json::format_key(out, "city");
        json::format_string(out, t.addr.city);
    }
    out.push('}');
}

struct DomRes { count: i64, msg: const u8[:], ok: bool }

// Dynamic DOM inspection: top-level member/element count plus the "msg"
// string member ("" when absent or not a string). ok=false on malformed JSON.
fn dom_summary(body: u8[:], doc: json::Node[>..]&, decoded: u8[>..]&) -> DomRes {
    var d = DomRes { count: 0, msg: "", ok: false };
    let root, _err = json::parse(body, doc, decoded);
    if !root { return d; }
    if root {
        json::each(root) { child =>
            d.count++;
        };
    }
    let m, mok = json::as_string(json::member(root, "msg"));
    if mok {
        d.msg = m;
    }
    d.ok = true;
    return d;
}

fn emit_dom_res(out: u8[>..]&, d: DomRes&) {
    out.push('{');
    json::format_key(out, "ok");
    json::format_bool(out, true);
    out.push(',');
    json::format_key(out, "count");
    json::format_int(out, d.count);
    out.push(',');
    json::format_key(out, "msg");
    json::format_string(out, d.msg);
    out.push('}');
}

// GET /json payload: standard greeting plus a realistic nested struct.
fn emit_hello_json(out: u8[>..]&) {
    out.push('{');
    json::format_key(out, "message");
    json::format_string(out, "Hello, World!");
    out.push(',');
    json::format_key(out, "user");
    out.push('{');
    json::format_key(out, "id");
    json::format_int(out, 42);
    out.push(',');
    json::format_key(out, "name");
    json::format_string(out, "Ada Lovelace");
    out.push(',');
    json::format_key(out, "score");
    json::format_number(out, 9.75);
    out.push(',');
    json::format_key(out, "active");
    json::format_bool(out, true);
    out.push(',');
    json::format_key(out, "tags");
    out.push('[');
    json::format_string(out, "goose");
    out.push(',');
    json::format_string(out, "honk");
    out.append("]}}");
}

// --- Cross-framework benchmark workloads (TechEmpower-shaped, exact bodies) ---

// W2: serialize {"message":"Hello, World!"} dynamically per request.
fn emit_bench_msg(out: u8[>..]&) {
    out.push('{');
    json::format_key(out, "message");
    json::format_string(out, "Hello, World!");
    out.push('}');
}

// W3: serialize {"id":"<id>","role":"<role>"} per request.
fn emit_bench_user(out: u8[>..]&, id: const u8[:], role: const u8[:]) {
    out.push('{');
    json::format_key(out, "id");
    json::format_string(out, id);
    out.push(',');
    json::format_key(out, "role");
    json::format_string(out, role);
    out.push('}');
}

struct BenchUser {
    name: const u8[:],
    has_name: bool,
    age: i64,
    has_age: bool,
    active: bool,
    has_active: bool,
}

// W4: strict parse of {name: string, age: int, active: bool}; unknown keys
// skipped. False on malformed JSON, trailing tokens, type mismatch, or any
// missing required field. Caller additionally rejects empty names.
fn parse_bench_user(r: json::Reader&, scratch: u8[>..]&, t: BenchUser&) -> bool {
    json::each_member(r) { key =>
        if key == "name" {
            t.name = json::read_string(r, scratch);
            t.has_name = true;
        } else if key == "age" {
            t.age = json::read_int(r);
            t.has_age = true;
        } else if key == "active" {
            t.active = json::read_bool(r);
            t.has_active = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) { return false; }
    if !t.has_name || !t.has_age || !t.has_active { return false; }
    return true;
}

// W4: serialize {"created":true,"name":"<name>","age":<age>} per request.
fn emit_bench_created(out: u8[>..]&, t: BenchUser&) {
    out.push('{');
    json::format_key(out, "created");
    json::format_bool(out, true);
    out.push(',');
    json::format_key(out, "name");
    json::format_string(out, t.name);
    out.push(',');
    json::format_key(out, "age");
    json::format_int(out, t.age);
    out.push('}');
}

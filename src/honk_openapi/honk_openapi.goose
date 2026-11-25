// honk_openapi.goose -- opt-in OpenAPI 3.1.0 JSON generator + interactive Docs UI (`honk::`).
//
// Opt-in submodule (`import honk.src.honk_openapi.honk_openapi;`): zero bytes
// compiled into binaries that do not import it. Automatically converts Honk
// `:param` route patterns (`/users/:id`) into OpenAPI `{param}` templates +
// path parameter schemas, merges operations sharing the same path, and serves
// an interactive Scalar API Reference UI via `app.docs("/docs", "/openapi.json", "My API")`.

namespace honk;

import std;
import json;
import src.honk_ctx.honk_ctx;
import src.honk_app.honk_app;

struct OpDef {
    method: const u8[:],
    route: const u8[:],
    summary: const u8[:],
    req_schema: const u8[:],
    int_params: bool,
    authed: bool,
}

struct OpenApiSpec {
    title: const u8[:],
    version: const u8[:],
    description: const u8[:],
    server_url: const u8[:],
    has_bearer: bool,
    ops: OpDef[64],
    n_ops: i64,
}

inline fn desc(s: OpenApiSpec&, text: const u8[:]) {
    s.description = text;
}

inline fn server(s: OpenApiSpec&, url: const u8[:]) {
    s.server_url = url;
}

inline fn bearer_auth(s: OpenApiSpec&) {
    s.has_bearer = true;
}

fn push_op(s: OpenApiSpec&, method: const u8[:], route: const u8[:], summary: const u8[:],
           req_schema: const u8[:], int_params: bool, authed: bool) {
    if s.n_ops >= 64 { return; }
    if authed { s.has_bearer = true; }
    s.ops[s.n_ops] = OpDef {
        method: method,
        route: route,
        summary: summary,
        req_schema: req_schema,
        int_params: int_params,
        authed: authed,
    };
    s.n_ops++;
}

inline fn op(s: OpenApiSpec&, method: const u8[:], route: const u8[:], summary: const u8[:]) {
    push_op(s, method, route, summary, "", false, false);
}

inline fn op_int(s: OpenApiSpec&, method: const u8[:], route: const u8[:], summary: const u8[:]) {
    push_op(s, method, route, summary, "", true, false);
}

inline fn op_body(s: OpenApiSpec&, method: const u8[:], route: const u8[:], summary: const u8[:], json_schema: const u8[:]) {
    push_op(s, method, route, summary, json_schema, false, false);
}

inline fn op_auth(s: OpenApiSpec&, method: const u8[:], route: const u8[:], summary: const u8[:]) {
    push_op(s, method, route, summary, "", false, true);
}

// Convert Honk route (`/users/:id`, `/files/*`) into OpenAPI path (`/users/{id}`, `/files/{path}`).
fn format_oa_path(route: const u8[:], out: u8[>..]&) -> const u8[:] {
    let start = out.len;
    var i: i64 = 0;
    while i < route.len {
        if route[i] == ':' && (i == 0 || route[i - 1] == '/') {
            out.push('{');
            i++;
            while i < route.len && route[i] != '/' {
                out.push(route[i]);
                i++;
            }
            out.push('}');
        } else if route[i] == '*' && (i == 0 || route[i - 1] == '/') {
            out.append("{path}");
            i++;
        } else {
            out.push(route[i]);
            i++;
        }
    }
    return out[start..];
}

fn same_oa_path(a: const u8[:], b: const u8[:], scratch: u8[>..]&) -> bool {
    let s0 = scratch.len;
    let pa = format_oa_path(a, scratch);
    let alen = pa.len;
    let pb = format_oa_path(b, scratch);
    let eq = scratch[s0 .. s0 + alen] == pb;
    return eq;
}

fn emit_path_params(route: const u8[:], int_first: bool, out: u8[>..]&) {
    var has_any = false;
    var param_idx: i64 = 0;
    var i: i64 = 0;
    while i < route.len {
        let is_named = route[i] == ':' && (i == 0 || route[i - 1] == '/') && i + 1 < route.len;
        let is_wild = route[i] == '*' && (i == 0 || route[i - 1] == '/');
        if is_named || is_wild {
            var ps: i64 = 0;
            var pe: i64 = 0;
            if is_named {
                i++;
                ps = i;
                while i < route.len && route[i] != '/' { i++; }
                pe = i;
            } else {
                i++;
            }
            if !has_any {
                out.push(',');
                json::format_key(out, "parameters");
                out.push('[');
                has_any = true;
            } else {
                out.push(',');
            }
            out.push('{');
            json::format_key(out, "name");
            if is_named {
                json::format_string(out, route[ps..pe]);
            } else {
                json::format_string(out, "path");
            }
            out.append(",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":");
            if int_first && param_idx == 0 && is_named {
                out.append("\"integer\"}}");
            } else {
                out.append("\"string\"}}");
            }
            param_idx++;
        } else {
            i++;
        }
    }
    if has_any {
        out.push(']');
    }
}

fn emit_single_op(d: OpDef&, out: u8[>..]&) {
    // Lowercase HTTP method key ("GET" -> "get")
    out.push('"');
    for ch in d.method {
        let lc: u8 = if ch >= 'A' && ch <= 'Z' { ch | 32 } else { ch };
        out.push(lc);
    }
    out.append("\":{");
    json::format_key(out, "summary");
    json::format_string(out, d.summary);
    emit_path_params(d.route, d.int_params, out);
    if d.req_schema.len > 0 {
        out.append(",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":");
        out.append(d.req_schema);
        out.append("}}}");
    }
    if d.authed {
        out.append(",\"security\":[{\"bearerAuth\":[]}]");
    }
    if d.method == "POST" {
        out.append(",\"responses\":{\"201\":{\"description\":\"Created\"},\"200\":{\"description\":\"OK\"}}");
    } else if d.method == "DELETE" {
        out.append(",\"responses\":{\"204\":{\"description\":\"No Content\"},\"200\":{\"description\":\"OK\"}}");
    } else {
        out.append(",\"responses\":{\"200\":{\"description\":\"OK\"}}");
    }
    out.push('}');
}

fn render_openapi_json(spec: OpenApiSpec&, out: u8[>..]&, scratch: u8[>..]&) -> const u8[:] {
    let start = out.len;
    out.append("{\"openapi\":\"3.1.0\",\"info\":{");
    json::format_key(out, "title");
    json::format_string(out, spec.title);
    out.push(',');
    json::format_key(out, "version");
    json::format_string(out, spec.version);
    if spec.description.len > 0 {
        out.push(',');
        json::format_key(out, "description");
        json::format_string(out, spec.description);
    }
    out.push('}');

    if spec.server_url.len > 0 {
        out.append(",\"servers\":[{");
        json::format_key(out, "url");
        json::format_string(out, spec.server_url);
        out.append("}]");
    }

    out.append(",\"paths\":{");
    var emitted: bool[64] = [false; 64];
    var first_path = true;
    let n = if spec.n_ops <= 64 { spec.n_ops } else { 64 };
    for i in n {
        if emitted[i] { continue; }
        if !first_path { out.push(','); }
        first_path = false;
        let oa_p = format_oa_path(spec.ops[i].route, scratch);
        json::format_key(out, oa_p);
        out.push('{');
        emit_single_op(spec.ops[i], out);
        emitted[i] = true;

        var j = i + 1;
        while j < n {
            if !emitted[j] && same_oa_path(spec.ops[i].route, spec.ops[j].route, scratch) {
                out.push(',');
                emit_single_op(spec.ops[j], out);
                emitted[j] = true;
            }
            j++;
        }
        out.push('}');
    }
    out.push('}');

    if spec.has_bearer {
        out.append(",\"components\":{\"securitySchemes\":{\"bearerAuth\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}}}");
    }
    out.push('}');
    return out[start..];
}

inline fn openapi_run<F>(s: OpenApiSpec&) {
    F(s);
}

// Serve an OpenAPI 3.1.0 JSON document at `route` (e.g. `"/openapi.json"`).
inline fn openapi<F>(app: Ctx&, route: const u8[:], title: const u8[:], version: const u8[:]) {
    app.get(route) {
        let empty_s: const u8[:] = if false { app.tmp[..0] } else { "" };
        let empty_op = OpDef { method: empty_s, route: empty_s, summary: empty_s, req_schema: empty_s, int_params: false, authed: false };
        var spec = OpenApiSpec {
            title: title,
            version: version,
            description: empty_s,
            server_url: empty_s,
            has_bearer: false,
            ops: [empty_op; 64],
            n_ops: 0,
        };
        openapi_run(spec) { sp => F(sp); };
        let body = render_openapi_json(spec, app.res, app.tmp);
        app.json_raw(200, body);
    };
}

inline fn append_html_escaped(out: u8[>..]&, s: const u8[:]) {
    for ch in s {
        if ch == '&' { out.append("&amp;"); }
        else if ch == '<' { out.append("&lt;"); }
        else if ch == '>' { out.append("&gt;"); }
        else if ch == '"' { out.append("&quot;"); }
        else { out.push(ch); }
    }
}

// Serve an interactive Scalar API Reference UI at `route` (e.g. `app.docs("/docs", "/openapi.json", "My API")`).
inline fn docs(app: Ctx&, route: const u8[:], spec_url: const u8[:], title: const u8[:] = "API Reference") {
    app.get(route) {
        let start = app.res.len;
        app.res.append("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
        append_html_escaped(app.res, title);
        app.res.append("</title></head><body><script id=\"api-reference\" data-url=\"");
        append_html_escaped(app.res, spec_url);
        app.res.append("\"></script><script src=\"https://cdn.jsdelivr.net/npm/@scalar/api-reference\"></script></body></html>");
        app.set_header("Cache-Control", "public, max-age=300");
        app.html(200, app.res[start..]);
    };
}

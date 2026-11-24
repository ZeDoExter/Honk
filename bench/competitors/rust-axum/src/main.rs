// Axum contender: single-thread Tokio, serde_json, manual W4 validation.
use axum::{
    body::Bytes,
    extract::{Path, Query, Request},
    http::StatusCode,
    middleware::{from_fn, Next},
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde_json::{json, Value};
use std::collections::HashMap;

async fn plaintext() -> &'static str {
    "Hello, World!"
}

async fn json_msg() -> Json<Value> {
    Json(json!({ "message": "Hello, World!" }))
}

async fn frame_bench_hook(req: Request, next: Next) -> impl IntoResponse {
    let mut res = next.run(req).await;
    res.headers_mut()
        .insert("x-frame-bench", "1".parse().unwrap());
    res
}

async fn get_user(
    Path(id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Json<Value> {
    let role = params.get("role").cloned().unwrap_or_default();
    Json(json!({ "id": id, "role": role }))
}

async fn create_user(body: Bytes) -> impl IntoResponse {
    let v: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return (StatusCode::BAD_REQUEST, "Bad Request").into_response(),
    };
    let name = v.get("name").and_then(Value::as_str).unwrap_or("");
    let age = v.get("age").and_then(Value::as_i64);
    let active = v.get("active").and_then(Value::as_bool);
    if name.is_empty() || age.is_none() || active.is_none() {
        return (StatusCode::BAD_REQUEST, "Bad Request").into_response();
    }
    (
        StatusCode::CREATED,
        Json(json!({ "created": true, "name": name, "age": age.unwrap() })),
    )
        .into_response()
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let port: u16 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(18503);
    let user_route = Router::new()
        .route("/users/{id}", get(get_user))
        .layer(from_fn(frame_bench_hook));
    let app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json_msg))
        .route("/users", post(create_user))
        .merge(user_route);
    println!("axum listening on {port}");
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .unwrap();
    axum::serve(listener, app).await.unwrap();
}

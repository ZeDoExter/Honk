// src/honk.goose -- the Honk package entry: single-import barrel for apps.
//
//   import honk from "../../src";
//
// (The package is `honk`, rooted at `src/`: the entry matches the package
// name, not the directory.) Re-exports the whole serving stack: transport
// (honk_net), Context API (honk_ctx), turn runner (honk_serve), App route DSL
// (honk_app), and static files (honk_static). Everything stays usable under
// its usual name: honk::listen/serve/request, app.get/post/...,
// try_serve_file, static_dir. honk_sqlite stays opt-in (it pulls -lsqlite3):
// apps that need SQLite add one more line:
//   import honk.honk_sqlite.honk_sqlite;
// and list the shim in their .build file. See docs/GUIDE.md.

import honk_net.honk_net;
import honk_ctx.honk_ctx;
import honk_serve.honk_serve;
import honk_app.honk_app;
import honk_static.honk_static;

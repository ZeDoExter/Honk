// honk.goose -- Honk package entry at repository root.
//
// Apps import Honk with a single line (no main.build sidecar needed):
//   import honk from "ZeDoExter/Honk@v0.6.0";   // pinned from GitHub
//   import honk from "../Honk";                 // relative local checkout
//
// Opt-in SQLite lives in the sibling `sqlite/` package so non-DB binaries
// never link -lsqlite3:
//   import honk_sqlite from "../Honk/sqlite";

import src.honk_net.honk_net;
import src.honk_ctx.honk_ctx;
import src.honk_serve.honk_serve;
import src.honk_app.honk_app;
import src.honk_static.honk_static;

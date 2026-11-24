# Development Log (v0.1.0 history)

How Honk was built, in order. Preserved as written (paths updated to the
production layout where mechanical); start here to understand *why* the code
looks the way it does.

| Report | Covers |
|---|---|
| `phase0-report.md` | Goose toolchain verification, stdlib networking/JSON audit, shim design |
| `step1a-spike-report.md` | Buffer-design spikes (3 candidates) vs bare-C control |
| `step1b-report.md` | Full HTTP/1.1 transport, stack discipline, caps, soak test, protocol |
| `phase2-report.md` | Framework layer (Ctx/router/middleware/JSON), BCE + codegen audit |
| `phase3-report.md` | 10-framework shootout (method, versions, raw rounds) |
| `phase5-report.md` | Toolchain setup, `sendfile`, SQLite, full-stack app, v0.1.0 gates |

Live docs: [`../QUICKSTART.md`](../QUICKSTART.md), [`../GUIDE.md`](../GUIDE.md),
[`../API.md`](../API.md), [`../DECISIONS.md`](../DECISIONS.md).

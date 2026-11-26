# Honk Chat (`examples/chat/`)

Multi-room chat on Honk `v1.0` — exercises non-blocking WebSockets, JWT auth,
SQLite history, and per-message rate limits end to end.

```sh
./honk dev examples/chat     # http://127.0.0.1:18080/ (single worker!)
```

## Design notes

- **Rooms**: `GET /ws/:room?token=<jwt>` upgrades; messages fan out to room
  members from a process-local table (hence single worker — set no
  `$HONK_WORKERS`; multi-worker fan-out needs an external broker).
- **Auth**: JWT (`HS256`, 24h) from `POST /login {"user":...}` (1–32 chars),
  verified at handshake from `?token=`; message turns reuse the stored identity.
- **History**: every message persists (`msgs` table); `GET /history/:room`
- **Limits**: 120 msgs/min per IP, 512-byte messages, 256 members, 1024
  upgrades/worker (core caps) — overfull rooms get WS close `1013`.
- **Presence**: browsers can't WS-ping, so the client sends `{"hb":1}` on
  connect + every 25s (beats the 30s idle timeout, joins instantly, never
  broadcast or stored) and auto-reconnects on close.

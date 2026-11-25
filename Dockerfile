# syntax=docker/dockerfile:1
# Honk example server, zero-install: builds Goose (pinned) + the app, then
# ships only the static-ish binary on a slim base.
#
#   docker build -t honk:quickstart .
#   docker run --rm -p 18080:18080 honk:quickstart
#   curl http://127.0.0.1:18080/
#
# For your own app, copy this file and change the `goose build` line to your
# root .goose file (keeping the src/ + shim layout it imports).

# ---- builder: toolchain + pinned Goose (via ./honk setup) + Honk app ----
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake g++ gcc python3 make libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /honk
COPY honk.py honk honk.goose honk.build ./
RUN ./honk setup
COPY src/ ./src/
COPY examples/quickstart/ ./examples/quickstart/
RUN ./goose_repo/build-linux/goose build examples/quickstart/app.goose \
      -o /honk/app \
 && ls -la /honk/app

# ---- runtime: libc-only slim image + one binary ----
# NOTE: debian 13 (glibc 2.41) to satisfy the ubuntu:24.04-built binary.
FROM debian:13-slim AS runtime
COPY --from=builder /honk/app /usr/local/bin/app
EXPOSE 18080
CMD ["/usr/local/bin/app", "18080"]

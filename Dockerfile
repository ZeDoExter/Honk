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

# ---- builder: toolchain + Goose (pinned) + Honk app ----
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake g++ gcc python3 make \
 && rm -rf /var/lib/apt/lists/*

ARG GOOSE_COMMIT=2239b92eb2ae0e8f390f98640b09ff57a17698fc
RUN git clone https://github.com/aardappel/goose.git /opt/goose \
 && cd /opt/goose && git checkout "${GOOSE_COMMIT}" \
 && cmake -B build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build --config Release -j"$(nproc)"

WORKDIR /honk
COPY src/ ./src/
COPY examples/quickstart/ ./examples/quickstart/
RUN /opt/goose/build/goose build examples/quickstart/app.goose \
      -o /honk/app \
 && ls -la /honk/app

# ---- runtime: libc-only slim image + one binary ----
# NOTE: debian 13 (glibc 2.41) to satisfy the ubuntu:24.04-built binary.
FROM debian:13-slim AS runtime
COPY --from=builder /honk/app /usr/local/bin/app
EXPOSE 18080
CMD ["/usr/local/bin/app", "18080"]

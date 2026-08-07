# syntax=docker/dockerfile:1
#
# Builds one example under examples/ into an OTP release image.
# The build context must be the repository root: every example depends on the
# library through {:exclosured, path: "../.."}.
#
#   docker build -f examples/Dockerfile --build-arg EXAMPLE=brotli_compress .

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.4.3-debian-trixie-20260803
ARG NODE_IMAGE=node:24.19.0-trixie-slim
ARG RUNTIME_IMAGE=debian:trixie-slim

FROM ${NODE_IMAGE} AS node

FROM ${ELIXIR_IMAGE} AS builder

ARG EXAMPLE
ARG RUST_VERSION=1.95.0
# Must match the wasm-bindgen crate version the guest crate resolves to.
ARG WASM_BINDGEN_VERSION=0.2.114

RUN test -n "${EXAMPLE}" || { echo "build arg EXAMPLE is required"; exit 1; }

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/rustup
ENV PATH=/opt/cargo/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# Only live_svelte_wasm and live_vue_wasm need it, but the build stage is
# discarded either way.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# The :exclosured compiler shells out to rustup to verify the wasm32 target,
# so rustup itself has to be on PATH — a bare cargo is not enough.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}" \
        --target wasm32-unknown-unknown

RUN cargo install wasm-bindgen-cli --version "${WASM_BINDGEN_VERSION}" --locked

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src
COPY . .

WORKDIR /src/examples/${EXAMPLE}

RUN mix deps.get --only prod

# Runs the :exclosured compiler, which cargo-builds the inline defwasm crates
# to wasm32 and writes priv/static/wasm.
RUN mix compile

# Mirrors extra/run_example.sh: most examples bundle with the esbuild hex
# package, the two framework demos have their own toolchains.
RUN set -eu; \
    if [ -f assets/package.json ]; then npm --prefix assets ci || npm --prefix assets install; fi; \
    case "${EXAMPLE}" in \
      live_svelte_wasm) cd assets && node build.js ;; \
      live_vue_wasm)    cd assets && npx vite build ;; \
      *)                mix esbuild.install --if-missing && mix esbuild "${EXAMPLE}" --minify ;; \
    esac

RUN mix release --overwrite --path /app


FROM ${RUNTIME_IMAGE}

ARG EXAMPLE

ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libncurses6 libssl3 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 app

COPY --from=builder --chown=app:app /app /app

RUN printf '#!/bin/sh\nexec /app/bin/%s "$@"\n' "${EXAMPLE}" > /usr/local/bin/entrypoint \
    && chmod +x /usr/local/bin/entrypoint

USER app
WORKDIR /app

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["start"]

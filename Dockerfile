# fumehood: one image for trying it out, and the builder of the release
# tarball the VM install uses (docs/install.md).
#
#   docker build -t fumehood .     # the image
#   scripts/build-release.sh       # dist/fumehood-*.tar.gz for the VM
#
# Built on Debian bookworm, so the tarball runs on Debian 12+ and Ubuntu 24.04+.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-debian-bookworm-20260918-slim
ARG NODE_IMAGE=node:24.21.0-bookworm-slim
ARG RUNNER_IMAGE=debian:bookworm-20260918-slim

# -- the Vue UI -> priv/static -------------------------------------------------
FROM ${NODE_IMAGE} AS ui
RUN npm install --global pnpm@12
WORKDIR /app/assets
COPY assets/package.json assets/pnpm-lock.yaml assets/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY assets/ ./
RUN pnpm build

# -- the Elixir release --------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY lib lib
COPY priv priv
COPY --from=ui /app/priv/static priv/static
COPY config/runtime.exs config/
COPY rel rel
RUN mix compile && mix release

# -- the image -----------------------------------------------------------------
FROM ${RUNNER_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 libsctp1 ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir /data && chown nobody:nogroup /data
ENV LANG=C.UTF-8 \
    PHX_SERVER=true \
    RELEASE_DISTRIBUTION=none \
    DATABASE_PATH=/data/fumehood.db \
    FUMEHOOD_CONFIG=/etc/fumehood/fumehood.toml
WORKDIR /app
COPY --from=build --chown=nobody:root /app/_build/prod/rel/fumehood ./
USER nobody
VOLUME /data
EXPOSE 4000
CMD ["/app/bin/fumehood", "start"]

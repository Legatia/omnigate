# omnigate control plane: an Elixir release on Alpine.
#
#   docker build -t omnigate-control -f control/Dockerfile .
#
# The build context is the repository root, so that the license files can be
# copied into the image (.dockerignore keeps the context to what is needed).

FROM elixir:1.20.5-otp-29-alpine AS build
ENV MIX_ENV=prod
WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so they are cached until mix.exs or mix.lock change.
COPY control/mix.exs control/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY control/config ./config
COPY control/lib ./lib
RUN mix release --path /out

# Remember which Alpine the runtime was built against; the final stage must match.
RUN cut -d. -f1,2 /etc/alpine-release > /alpine-version


FROM alpine:3.24
# Shared libraries the Erlang runtime links against, and root certificates
# for TLS to providers and buckets.
RUN apk add --no-cache libstdc++ libgcc ncurses-libs openssl ca-certificates \
 && adduser -D -u 10001 -h /data omnigate

COPY --from=build /out /app
COPY --from=build /alpine-version /app/alpine-version
# The license terms travel with every copy of the program.
COPY LICENSE COMMERCIAL.md .github/release/README.txt /licenses/
RUN test "$(cut -d. -f1,2 /etc/alpine-release)" = "$(cat /app/alpine-version)" \
 || { echo "runtime Alpine $(cat /etc/alpine-release) does not match build Alpine $(cat /app/alpine-version): change the FROM line" >&2; exit 1; }

USER 10001:10001
WORKDIR /data
VOLUME /data

# Inside a container "all interfaces" means the container's own network; what
# the outside world can reach is decided by which ports are published.
ENV OMNIGATE_CONTROL_BIND=0.0.0.0 \
    OMNIGATE_CONFIG=/config/omnigate.json \
    OMNIGATE_LEDGER=/data/ledger.jsonl \
    OMNIGATE_JOBS=/data/jobs.jsonl \
    OMNIGATE_KEYS=/data/keys.json \
    OMNIGATE_AUDIT_LOG=/data/audit.jsonl \
    OMNIGATE_MEDIA_DIR=/data/media \
    RELEASE_DISTRIBUTION=none \
    LANG=C.UTF-8
EXPOSE 4000

# The port opens only after the ledger has been read. That is under a second
# from a snapshot, but a first start on a large ledger written by an older
# version replays all of it (about 11 s per million events measured), so the
# start period is generous: failures inside it do not count against the
# container, and a healthy answer ends it early.
# (The port is the one the control plane was told to listen on, if any.)
HEALTHCHECK --interval=10s --timeout=3s --start-period=120s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${OMNIGATE_CONTROL_PORT:-4000}/readyz" || exit 1

CMD ["/app/bin/omnigate_control", "start"]

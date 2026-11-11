# omnigate data plane: a static binary on an empty image.
#
#   docker build -t omnigate-dataplane -f dataplane/Dockerfile .
#
# The build context is the repository root, so that the license files can be
# copied into the image (.dockerignore keeps the context to what is needed).
#
# The build stage downloads the Zig compiler from ziglang.org and checks it
# against the SHA-256 published in https://ziglang.org/download/index.json.

FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  sum="$ZIG_SHA256_X86_64" ;; \
      aarch64) sum="$ZIG_SHA256_AARCH64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"; \
    echo "${sum}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz

WORKDIR /src
COPY dataplane/build.zig dataplane/build.zig.zon ./
COPY dataplane/src ./src

# Unit tests run as part of the image build, then a static (musl) release build.
RUN /opt/zig/zig build test --summary all \
 && /opt/zig/zig build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget="$(uname -m)-linux-musl" --prefix /out

# The spool and config cache live in /data; make it writable by the runtime user.
RUN mkdir /data && chown 10001:10001 /data

# The license terms travel with every copy of the program.
COPY LICENSE COMMERCIAL.md .github/release/README.txt /licenses/


FROM scratch
# Root certificates, for TLS to the providers.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/bin/omnigate-dp /omnigate-dp
COPY --from=build --chown=10001:10001 /data /data
# License terms and where the documentation is.
COPY --from=build /licenses /licenses

USER 10001:10001
WORKDIR /data
VOLUME /data

ENV OMNIGATE_LISTEN=0.0.0.0:8080 \
    OMNIGATE_CONTROL_URL=http://control:4000
EXPOSE 8080

# The image has no shell and no curl, so the binary checks itself: it asks
# the address in OMNIGATE_LISTEN for /healthz and exits 0 on a 200.
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 CMD ["/omnigate-dp", "healthcheck"]

ENTRYPOINT ["/omnigate-dp"]

# omnigate data plane, release image: the binaries the release workflow
# cross-compiled, on an empty image. Used only by .github/workflows/release.yml.
#
# dataplane/Dockerfile (what `docker compose build` and the container test
# use) downloads the Zig compiler for the architecture it runs on and compiles
# inside the image. For a multi-architecture release that would mean compiling
# the arm64 image under QEMU emulation. Zig cross-compiles, so the release
# workflow builds both Linux binaries natively on the runner instead and this
# file only assembles them. The published image therefore contains exactly the
# binaries in the release archives omnigate-dp-<version>-x86_64-linux-musl and
# omnigate-dp-<version>-aarch64-linux-musl.
#
# Build context: a directory holding
#
#   bin/amd64/omnigate-dp     the x86_64-linux-musl build
#   bin/arm64/omnigate-dp     the aarch64-linux-musl build
#
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -f .github/release/dataplane.Dockerfile <context>
#
# Everything from "FROM scratch" down must stay the same as the final stage of
# dataplane/Dockerfile, except for where the files are copied from. The
# release workflow compares the two and fails when they have drifted apart.

# Runs on the build machine's own architecture for every target platform:
# nothing in this stage is executed under emulation.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS files
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 bin/${TARGETARCH}/omnigate-dp /out/bin/omnigate-dp

# The spool and config cache live in /data; make it writable by the runtime user.
RUN mkdir /data && chown 10001:10001 /data


FROM scratch
# Root certificates, for TLS to the providers.
COPY --from=files /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=files /out/bin/omnigate-dp /omnigate-dp
COPY --from=files --chown=10001:10001 /data /data

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

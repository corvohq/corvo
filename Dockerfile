FROM debian:bookworm-slim AS build

ARG TARGETARCH
ARG ZIG_VERSION=0.15.2

RUN apt-get update && \
    apt-get install -y wget xz-utils libsqlite3-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz -O /tmp/zig.tar.xz && \
    tar xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY . .
RUN zig build -Drelease

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates libsqlite3-0 && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/zig-out/bin/corvo-v2 /usr/local/bin/corvo-v2
COPY --from=build /app/zig-out/bin/corvo-inspect /usr/local/bin/corvo-inspect

RUN mkdir -p /data
VOLUME /data

EXPOSE 9878

ENTRYPOINT ["corvo-v2"]
CMD ["--data-dir", "/data", "--bind", "0.0.0.0"]

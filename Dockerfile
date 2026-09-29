FROM --platform=$BUILDPLATFORM alpine:3.24 AS build

RUN apk add --no-cache zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

ARG TARGETARCH
RUN case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac \
 && zig build -Doptimize=ReleaseSafe -Dtarget="$arch-linux-musl" --prefix /out

FROM scratch

COPY --from=build /out/bin/wsproxy /wsproxy

USER 65532:65532
EXPOSE 5999

ENTRYPOINT ["/wsproxy"]

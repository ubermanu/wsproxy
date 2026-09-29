ARG ZIG_VERSION=0.16.0

FROM --platform=$BUILDPLATFORM python:3.13-slim AS build

ARG ZIG_VERSION
ARG TARGETPLATFORM

RUN pip install --no-cache-dir "ziglang==${ZIG_VERSION}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

RUN case "$TARGETPLATFORM" in \
      linux/amd64) target=x86_64-linux-musl ;; \
      linux/arm64) target=aarch64-linux-musl ;; \
      *) echo "unsupported target platform: $TARGETPLATFORM" >&2; exit 1 ;; \
    esac \
 && python -m ziglang build -Doptimize=ReleaseSafe -Dtarget="$target" --prefix /out

FROM scratch

COPY --from=build /out/bin/wsproxy /wsproxy

USER 65532:65532
EXPOSE 5999

ENTRYPOINT ["/wsproxy"]

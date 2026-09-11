ARG RUST_VERSION=1.98

FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim AS build

ARG TARGETPLATFORM

# The crate has no C dependencies, so rust-lld links the musl targets without a
# cross toolchain. Proc macros still build for the glibc host with its own linker.
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld

WORKDIR /src

RUN case "$TARGETPLATFORM" in \
      linux/amd64) target=x86_64-unknown-linux-musl ;; \
      linux/arm64) target=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported target platform: $TARGETPLATFORM" >&2; exit 1 ;; \
    esac \
 && echo "$target" > /target \
 && rustup target add "$target"

COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
 && echo 'fn main() {}' > src/main.rs \
 && touch src/lib.rs \
 && cargo build --release --locked --target "$(cat /target)" \
 && rm -rf src

COPY src ./src
RUN touch src/main.rs src/lib.rs \
 && cargo build --release --locked --target "$(cat /target)" \
 && cp "target/$(cat /target)/release/wsproxy" /wsproxy

FROM scratch

COPY --from=build /wsproxy /wsproxy

USER 65532:65532
EXPOSE 5999

ENTRYPOINT ["/wsproxy"]

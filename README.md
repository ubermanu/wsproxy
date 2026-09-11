# wsproxy

WebSocket-to-TCP proxy that lets [roBrowserLegacy](https://github.com/MrAntares/roBrowserLegacy) talk to
an rAthena server. Rust, static musl binary, `scratch` image, ~2 MB.

Image: `ghcr.io/ubermanu/wsproxy`

## Why this repo exists

Upstream [herenow/wsProxy](https://github.com/herenow/wsProxy) is Node.js and ships no image. This is a
from-scratch reimplementation of the wire behaviour, not a wrapper around upstream. The reference for the
protocol is upstream `master` (`d5fba98`, 2025-03-25).

## Run

```bash
docker run -p 5999:5999 ghcr.io/ubermanu/wsproxy \
  -a 192.168.1.10:6900,192.168.1.10:6121,192.168.1.10:5121
```

Clients connect to `ws://<proxy-host>:5999/<target-host>:<target-port>`. The target is the URL path.

See `compose.yaml` for an rAthena stack example. Put TLS on your reverse proxy in front of port 5999.

## Options

| Flag | Default | Description |
| --- | --- | --- |
| `-p`, `--port` | `5999` | Listen port. Falls back to `$PORT`. |
| `-a`, `--allow` | none | Comma-separated allowlist of `host:port` targets. |
| `-h`, `--help` | | Print usage and exit. |

`PORT` and `RUST_LOG` are the only environment variables read. `RUST_LOG` sets the log filter, default
`info`.

## Behaviour

- The allowlist is an **exact string compare** against the URL path. `rathena:6900` and `172.18.0.2:6900`
  are different entries. That address is what the client asks for: the login address in `ROConfig`, then
  the `char_ip` / `map_ip` values rAthena sends back.
- A target outside the allowlist gets **HTTP 401** at the handshake, before the upgrade.
- **Without `-a` every target is allowed.** This matches upstream, and it is an open TCP relay usable for
  abuse from your IP. Always pass `-a`.
- Traffic is relayed verbatim in both directions. No framing, no transformation. Frames from the client
  are written as-is; each TCP read becomes one binary frame.
- Outbound connections are **forced to IPv4**, as upstream does. Inside Docker this avoids a target that
  resolves to an unroutable IPv6 address.
- Teardown is symmetric. The TCP side closing sends a WebSocket close frame; the WebSocket side closing
  shuts the TCP write side down. Neither side can leak a half-open connection.
- A `Sec-WebSocket-Protocol` request header is answered with its first entry, which is what upstream's
  `ws` library does by default. roBrowserLegacy does not send one.

## Not implemented

Upstream flags left out on purpose:

| Flag | Reason |
| --- | --- |
| `-s`, `-k`, `-c` (SSL) | TLS is terminated at the reverse proxy in front of this container. |
| `-r`, `--redirect` | Unused here; set the advertised `char_ip` / `map_ip` in rAthena instead. |
| `-t`, `--threads` | The tokio runtime already uses all cores. One process is enough. |

Upstream also answers a plain HTTP GET with `200 wsProxy running...`. This build does not; the port only
serves WebSocket upgrades.

## Tags

| Tag | Meaning |
| --- | --- |
| `latest` | Last successful build. |
| `nightly` | Same image, mirrors the rAthena Docker Hub naming. |
| `<YYYYMMDD>-<short-sha>` | Immutable. Pin this. |

A weekly workflow rebuilds the image, so Rust and base image updates are picked up. Publishing is gated
on `cargo fmt`, `cargo clippy -- -D warnings` and `cargo test`.

## Build

```bash
docker build -t wsproxy .
```

Build arg: `RUST_VERSION` (default `1.98`). The build stage always runs on the build platform and
cross-compiles to `x86_64-unknown-linux-musl` or `aarch64-unknown-linux-musl` with `rust-lld`, so
multi-arch builds need no QEMU. The crate has no C dependencies, so no cross toolchain is needed either.

Locally:

```bash
cargo test
cargo run -- -a 127.0.0.1:6900
```

No code from upstream wsProxy (GPL-2.0) is reused here. This repo has no licence yet.

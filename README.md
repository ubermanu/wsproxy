# wsproxy

WebSocket-to-TCP proxy that lets [roBrowserLegacy](https://github.com/MrAntares/roBrowserLegacy)
reach an rAthena server. Rust rewrite of [herenow/wsProxy](https://github.com/herenow/wsProxy),
which ships no image. Static musl binary on `scratch`, ~2 MB.

`ghcr.io/ubermanu/wsproxy`

## Run

```bash
docker run -p 5999:5999 ghcr.io/ubermanu/wsproxy \
  -a 192.168.1.10:6900,192.168.1.10:6121,192.168.1.10:5121
```

Clients connect to `ws://<proxy>:5999/<host>:<port>`. The target is the URL path.

- `-p`, `--port` — listen port, default `5999`, falls back to `$PORT`
- `-a`, `--allow` — comma-separated `host:port` allowlist
- `RUST_LOG` — log filter, default `info`

## Gotchas

- **Always pass `-a`.** Without it every target is allowed, which is an open TCP relay
  on your IP. Upstream behaves the same way.
- The allowlist is an **exact string compare** against the URL path, so `rathena:6900`
  and `172.18.0.2:6900` are different entries. The client asks for the login address in
  `ROConfig`, then the `char_ip` / `map_ip` values rAthena hands back — all three must
  be listed.
- Outbound connections are forced to IPv4, as upstream does.
- No TLS. Terminate it on the reverse proxy in front of port 5999.

## Tags

`latest` and `nightly` track the last successful build. `<YYYYMMDD>-<short-sha>` is
immutable — pin that one. A weekly workflow rebuilds to pick up Rust and base image
updates. Publishing is gated on `fmt`, `clippy -D warnings` and `test`.

## Build

```bash
cargo test
docker build -t wsproxy .
```

The build stage cross-compiles to musl, so multi-arch needs no QEMU.

No upstream code is reused. See `compose.yaml` for an rAthena stack example.

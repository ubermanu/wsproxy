# wsproxy

Proxies WebSocket connections to a TCP game server, for use by
[roBrowser](https://github.com/MrAntares/roBrowserLegacy).

Clients connect to `ws://<proxy>:5999/<host>:<port>`. The target is the URL
path. Traffic is relayed verbatim in both directions, and outbound connections
are forced to IPv4.

A Rust rewrite of [herenow/wsProxy](https://github.com/herenow/wsProxy), which
ships no image.

## Usage

```sh
wsproxy --allow 192.168.1.10:6900,192.168.1.10:6121,192.168.1.10:5121
```

| Option        | Environment | Default |
| ------------- | ----------- | ------- |
| `--port PORT` | `PORT`      | `5999`  |
| `--allow LIST`| —           | none    |
| —             | `RUST_LOG`  | `info`  |

## Allowlist

`--allow` takes `host:port` entries, comma separated, compared as exact
strings against the URL path. A client asks for the login address first, then
for the `char_ip` and `map_ip` values rAthena hands back, so list all three.
Anything else gets `401` before the upgrade.

> [!WARNING]
> Without `--allow` every target is permitted, which makes this an open TCP
> relay on your address. Upstream behaves the same way.

There is no TLS. Terminate it on the reverse proxy in front of the port.

## Docker

```sh
docker run --rm -p 5999:5999 ghcr.io/ubermanu/wsproxy \
  --allow 192.168.1.10:6900
```

Or as a Docker Compose service:

```yaml
services:
  wsproxy:
    image: ghcr.io/ubermanu/wsproxy
    ports:
      - "5999:5999"
    command: ["--allow", "192.168.1.10:6900"]
```

`latest` and `nightly` track the last build, `<YYYYMMDD>-<short-sha>` is
immutable.

## Build

```sh
cargo build --release
```

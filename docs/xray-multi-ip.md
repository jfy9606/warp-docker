# xray multi-IP mode

An alternative to the official-client mode: **one container, N SOCKS5 ports, N independent WARP tunnels** (and therefore N independent egress IPs). It is built on [Xray-core](https://github.com/XTLS/Xray-core) (WireGuard outbound) with wgcf-style registrations done natively against the Cloudflare API.

Unlike the main image it does **not** use the official `warp-svc` client: xray runs WireGuard entirely in userspace (gVisor, `noKernelTun`), so the container needs **no TUN device, no `NET_ADMIN`, no dbus, no `device_cgroup_rules`**. Trade-offs are listed at the bottom.

- **Single exit**: `XRAY_TUNNELS=1` — one SOCKS5 port, one WARP IP (a lighter drop-in replacement for the official mode when you don't need MASQUE/Zero Trust).
- **Multi exit**: `XRAY_TUNNELS=N` — N SOCKS5 ports, N independent WARP IPs in one container.

## ⚠️ Status (verified August 2026)

This mode works, but **general internet egress through WARP WireGuard is currently unreliable** — Cloudflare does not officially support third-party WireGuard clients and has been progressively restricting API-registered devices.

What was verified end-to-end (fresh device, real Cloudflare API):

- A newly registered device **does** get a working tunnel at first — non-Cloudflare destinations (`api.ipify.org`, `httpbin.org`, `google.com`) correctly return the WARP egress IP.
- Sessions then degrade or die within minutes: the server stops answering, re-handshakes are rejected, and often only Cloudflare-owned destinations (Cloudflare-proxied sites, `1.1.1.1`) keep working ("CF-only" state).
- The same behavior reproduces with **sing-box** and other third-party WireGuard clients using the identical registration, so this is **not an xray bug** — it is Cloudflare-side treatment of API-registered WireGuard devices.
- Registering many devices from one IP makes it worse: after a burst of registrations, even brand-new devices die within ~a minute (rate limiting).

Practical consequences:

- **Do not rely on this mode for production traffic.** For stable, supported WARP egress use the official-client mode (MASQUE) — the main `docker-compose.yml`.
- Treat the xray mode as **experimental**, useful for multi-IP prototyping or as a secondary exit.
- Rotation now **deletes the replaced device** on Cloudflare's side so identities don't pile up; keep rotation intervals long (hours, not minutes), and prefer not to re-register repeatedly in a short window.

## Prerequisites

- Docker with BuildKit (`docker compose build` does this automatically).
- The container must be able to reach `engage.cloudflareclient.com:2408` (UDP) and `api.cloudflareclient.com` (HTTPS) during registration.

## Quick start: single exit (1 tunnel / 1 IP)

```bash
# 1. build
docker build -f xray/Dockerfile -t warp-xray:latest .

# 2. run (one SOCKS5 on 1080)
docker run -d --name warp-xray \
  -p 1080:1080 \
  -e XRAY_TUNNELS=1 \
  -e XRAY_SOCKS_PORT=1080 \
  -e WARP_SLEEP=2 \
  -v "$PWD/data-xray:/var/lib/xray-warp" \
  warp-xray:latest

# 3. verify
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
# expect: warp=on, ip=<cloudflare ip>, colo=<datacenter>
```

The `data-xray` volume keeps the tunnel identity, so the IP survives restarts. Delete `data-xray/tunnel-0.json` (or the whole dir) to register a fresh identity.

## Quick start: multi exit (N tunnels / N IPs)

Configuration is done via a `.env` file (docker compose interpolates it automatically) — **no need to edit the compose file**. Start from the shipped example:

```bash
cp env.example .env
# edit .env: set XRAY_PORTS to the port range you want, e.g.
#   XRAY_PORTS=1080-1082   # 3 exits
#   XRAY_PORTS=1080-1081   # 2 exits (default)

docker compose -f docker-compose.xray.yml up -d --build

# verify every exit in a loop
for p in $(seq 1080 1082); do
  echo "== port $p =="
  curl -sS --max-time 20 --socks5-hostname 127.0.0.1:$p \
    https://cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
done
```

Each port shows its own IP (and usually a different `colo`). **`XRAY_PORTS` is the single knob**: the compose file runs the container in **host network mode**, so it listens directly on those host ports (no port mapping) and derives the tunnel count from the range (`1080-1082` → 3 tunnels). Set `WARP_IP_ROTATE_INTERVAL`, `WARP_LICENSE_KEY` and `WARP_SLEEP` in the same `.env`; see `env.example` for the full list. Changing `XRAY_PORTS` later only requires editing `.env` and `docker compose ... up -d` again.

## Rotating the IPs

### Periodic (all tunnels at once)

Add `WARP_IP_ROTATE_INTERVAL` (GNU `sleep` duration, e.g. `6h`, `30m`):

```bash
docker run -d --name warp-xray \
  -p 1080:1080 \
  -e XRAY_TUNNELS=1 \
  -e WARP_IP_ROTATE_INTERVAL=6h \
  -v "$PWD/data-xray:/var/lib/xray-warp" \
  warp-xray:latest
```

Each cycle re-registers **all** tunnels (new identities → new IPs), regenerates the config, validates it, and restarts xray to apply it (xray has no `SIGHUP` hot reload; the entrypoint restart loop brings it back up). All SOCKS5 ports blip briefly while the new handshakes complete; a failed cycle keeps the old config running and retries next interval.

### Manual

```bash
docker exec warp-xray /usr/local/bin/rotate.sh
docker logs -f warp-xray        # watch "tunnel 0: <old> -> <new>"
```

## Environment variables

With docker compose, put these in `.env` (see `env.example`). With plain `docker run`, pass them with `-e`.

| Variable | Default | Description |
|---|---|---|
| `XRAY_PORTS` | `1080-1081` | **Primary knob.** Host port range of the SOCKS5 exits (compose uses host network mode, so no port mapping); the tunnel count is derived from it (`1080-1082` → 3 tunnels on 1080/1081/1082). |
| `XRAY_TUNNELS` | `1` | Number of WARP tunnels / SOCKS5 ports. Only used when `XRAY_PORTS` is unset (plain `docker run`). |
| `XRAY_SOCKS_PORT` | `1080` | Base SOCKS5 port; tunnels use `1080 .. 1080+N-1`. Only used when `XRAY_PORTS` is unset. |
| `WARP_SLEEP` | `2` | Seconds to wait after startup / restart for the tunnels to handshake. |
| `WARP_IP_ROTATE_INTERVAL` | unset | If set, re-register all tunnels periodically and restart xray. |
| `WARP_LICENSE_KEY` | unset | Optional WARP+ license, applied to each new registration. |
| `WARP_PROXY` | unset | Optional `socks5://[user:pass@]host:port` upstream SOCKS5 proxy the WARP tunnels are chained through (`WireGuard -> SOCKS5 -> Cloudflare`). See [Chaining through an upstream SOCKS5 proxy](#chaining-through-an-upstream-socks5-proxy). |
| `XRAY_DATA_DIR` | `./data-xray` | Host dir mounted at `/var/lib/xray-warp` (tunnel identities). Compose-only. |
| `XRAY_VERSION` / `XRAY_IMAGE` / `XRAY_CONTAINER_NAME` / `XRAY_RESTART` | … | Compose-only: xray-core release to build, image tag, container name, restart policy. |
| `DATA_DIR` | `/var/lib/xray-warp` | Where tunnel identities are persisted inside the container. |
| `WARP_WG_MTU` | `1280` | WireGuard tunnel MTU (official WARP client default). |
| `WARP_WG_KEEPALIVE` | `25` | Peer keepalive interval, seconds (official WARP client default). |
| `WARP_API_BASE` / `WARP_CLIENT_VERSION` / `WARP_WG_PORT` | … | Advanced: API endpoint, client version header, WireGuard peer port (2408). |

## Chaining through an upstream SOCKS5 proxy

Set `WARP_PROXY` to run the WireGuard tunnels **through** an upstream SOCKS5 proxy instead of connecting to Cloudflare directly — e.g. when your network blocks Cloudflare endpoints but allows the proxy:

```bash
WARP_PROXY=socks5://user:pass@proxy.example.com:1080
```

Implementation: each wireguard outbound gets `"proxySettings": { "tag": "socks-out" }` and a socks outbound is added to the config. xray's wireguard outbound dials its peer endpoint through the passed dialer (see `proxy/wireguard/bind.go`), so the proxy chain carries the entire WireGuard session to Cloudflare. All N tunnels share the same upstream proxy; each keeps its own egress IP.

Requirements & behavior:

- **The upstream proxy MUST support SOCKS5 UDP ASSOCIATE** — xray has no `udp_over_tcp` equivalent, and WireGuard is UDP end to end. A TCP-only SOCKS5 proxy will never complete a WireGuard handshake.
- **Keep `XRAY_VERSION` pinned**: the proxy chain is verified against the pinned release 26.3.27. Newer xray-core releases refactored the wireguard outbound (the endpoint is now dialed directly via the system dialer) and may ignore `proxySettings` — do not bump `XRAY_VERSION` blindly if you rely on chaining.
- **Hostname resolution**: a proxy hostname is resolved once at startup and again at each rotation, using the container's DNS — which is outside the tunnel (userspace gVisor WireGuard never touches the system route table), so it is never circular. If the hostname cannot be resolved from the container, put an IP in `WARP_PROXY` (`socks5://1.2.3.4:1080`).
- **Registration through the proxy**: the Cloudflare API calls (registration, WARP+ license binding, rotation/device deletion) also go through the proxy, so the container needs no direct route to `api.cloudflareclient.com` — only the proxy does.
- **Auth**: `socks5://user:pass@host:port` (user/pass may be percent-encoded). IPv6 proxies are written `socks5://[::1]:1080`.
- **Client DNS** still resolves through tunnel 0, inside the chain, unchanged.

Verify after startup: `curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace` should report `warp=on` with a WARP egress IP — and the proxy's own access log should show the tunnel traffic arriving via the proxy.

## How it works

- `entrypoint.sh` registers one Cloudflare device per tunnel (missing ones only), renders `/etc/xray/config.json`, validates it (`xray run -test`), starts xray in a restart loop, and (optionally) the rotation loop.
- The xray config has one `wireguard` outbound per tunnel: `reserved` bytes decoded from the registration's `client_id`, the peer endpoint pinned to the IP returned by Cloudflare (avoids resolving the peer through the tunnel at startup), `noKernelTun: true` so WireGuard runs in userspace via gVisor (no TUN / `NET_ADMIN` needed).
- Each SOCKS5 inbound is routed to its own outbound via a routing rule; DNS queries go through tunnel 0 (routing rule for UDP/53; unmatched traffic falls through to the first outbound anyway).
- Keys are generated with `xray x25519 --std-encoding` (standard base64, which the Cloudflare API expects).

## Troubleshooting

- **`curl` times out / connection refused**: wait for `WARP_SLEEP` after startup, then check `docker logs warp-xray`. If the log shows the wireguard outbound started but no traffic, verify UDP 2408 is reachable from the container.
- **Registration fails at first start**: the container needs HTTPS access to `api.cloudflareclient.com`; check the `[FATAL] failed to register tunnel` line in the logs.
- **`warp=off` or wrong IP on an exit**: the tunnel did not come up — see the log for that outbound; then run `/usr/local/bin/rotate.sh` to re-register.
- **WARP+ license stops applying after a while**: a WARP+ account allows at most 5 linked devices; each rotation adds one. Remove old devices in the 1.1.1.1 app or drop `WARP_LICENSE_KEY` (free WARP has no device limit).
- **Want completely fresh identities**: stop the container, delete the `data-xray` directory (or the `tunnel-*.json` files), start again.

## Trade-offs vs. the official-client mode

| | xray mode | Official client (main image) |
|---|---|---|
| Tunnels per container | N (one per SOCKS5 port) | 1 |
| Protocol | WireGuard UDP:2408 only | MASQUE by default (more firewall-resistant) |
| Zero Trust / mdm.xml / org policies | ❌ not supported | ✅ supported |
| WARP+ license | ✅ applied per device (5-device limit) | ✅ same limit |
| Prerequisites | none (userspace gVisor, no TUN) | TUN + `NET_ADMIN` + device cgroup rule |
| Rotation | re-register all + restart (whole-instance reload, all ports blip) | `rotate-ip.sh` (tunnel-only reconnect, GOST untouched) |
| Hot reload | ❌ none (xray has no SIGHUP; rotation restarts the process) | n/a (GOST proxy is stateless) |

### Caveats

- **Session instability (see "Status" above)**: API-registered WARP WireGuard sessions degrade or drop within minutes and re-handshakes get rejected. This is Cloudflare-side and affects xray and sing-box alike; the official-client mode is the reliable path.
- **Registration rate limits**: every rotation creates one new device per tunnel; keep intervals long (hours). `rotate.sh` now deletes the replaced device from Cloudflare's side (`DELETE /reg/{id}`), so identities no longer pile up — but devices registered before this fix, or with older versions, still need manual cleanup in the 1.1.1.1 app.
- **No MASQUE / no Zero Trust**: use the main image if you need either.
- **UDP 2408** must be reachable from the container to `engage.cloudflareclient.com`.

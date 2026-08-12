# sing-box multi-IP mode

An alternative to the official-client mode: **one container, N SOCKS5 ports, N independent WARP tunnels** (and therefore N independent egress IPs). It is built on [sing-box](https://sing-box.sagernet.org/) (WireGuard endpoint model) with wgcf-style registrations done natively against the Cloudflare API.

Unlike the main image it does **not** use the official `warp-svc` client: sing-box runs WireGuard entirely in userspace, so the container needs **no TUN device, no `NET_ADMIN`, no dbus, no `device_cgroup_rules`**. Trade-offs are listed at the bottom.

- **Single exit**: `SINGBOX_TUNNELS=1` — one SOCKS5 port, one WARP IP (a lighter drop-in replacement for the official mode when you don't need MASQUE/Zero Trust).
- **Multi exit**: `SINGBOX_TUNNELS=N` — N SOCKS5 ports, N independent WARP IPs in one container.

## Prerequisites

- Docker with BuildKit (`docker compose build` does this automatically).
- The container must be able to reach `engage.cloudflareclient.com:2408` (UDP) and `api.cloudflareclient.com` (HTTPS) during registration.

## Quick start: single exit (1 tunnel / 1 IP)

```bash
# 1. build
docker build -f singbox/Dockerfile -t warp-singbox:latest .

# 2. run (one SOCKS5 on 1080)
docker run -d --name warp-singbox \
  -p 1080:1080 \
  -e SINGBOX_TUNNELS=1 \
  -e SINGBOX_SOCKS_PORT=1080 \
  -e WARP_SLEEP=2 \
  -v "$PWD/data-singbox:/var/lib/singbox-warp" \
  warp-singbox:latest

# 3. verify
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
# expect: warp=on, ip=<cloudflare ip>, colo=<datacenter>
```

The `data-singbox` volume keeps the tunnel identity, so the IP survives restarts. Delete `data-singbox/tunnel-0.json` (or the whole dir) to register a fresh identity.

## Quick start: multi exit (N tunnels / N IPs)

Configuration is done via a `.env` file (docker compose interpolates it automatically) — **no need to edit the compose file**. Start from the shipped example:

```bash
cp env.example .env
# edit .env: set SINGBOX_PORTS to the port range you want, e.g.
#   SINGBOX_PORTS=1080-1082   # 3 exits
#   SINGBOX_PORTS=1080-1081   # 2 exits (default)

docker compose -f docker-compose.singbox.yml up -d --build

# verify every exit in a loop
for p in $(seq 1080 1082); do
  echo "== port $p =="
  curl -sS --max-time 20 --socks5-hostname 127.0.0.1:$p \
    https://cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
done
```

Each port shows its own IP (and usually a different `colo`). **`SINGBOX_PORTS` is the single knob**: the port range is used both for the host port mapping and inside the container, which derives the tunnel count from it (`1080-1082` → 3 tunnels). Set `WARP_IP_ROTATE_INTERVAL`, `WARP_LICENSE_KEY` and `WARP_SLEEP` in the same `.env`; see `env.example` for the full list. Changing `SINGBOX_PORTS` later only requires editing `.env` and `docker compose ... up -d` again.

## Rotating the IPs

### Periodic (all tunnels at once)

Add `WARP_IP_ROTATE_INTERVAL` (GNU `sleep` duration, e.g. `6h`, `30m`):

```bash
docker run -d --name warp-singbox \
  -p 1080:1080 \
  -e SINGBOX_TUNNELS=1 \
  -e WARP_IP_ROTATE_INTERVAL=6h \
  -v "$PWD/data-singbox:/var/lib/singbox-warp" \
  warp-singbox:latest
```

Each cycle re-registers **all** tunnels (new identities → new IPs), regenerates the config, validates it, and hot-reloads sing-box via `SIGHUP`. All SOCKS5 ports blip briefly while the new handshakes complete; a failed cycle keeps the old config running and retries next interval.

### Manual

```bash
docker exec warp-singbox /usr/local/bin/rotate.sh
docker logs -f warp-singbox        # watch "tunnel 0: <old> -> <new>"
```

## Environment variables

With docker compose, put these in `.env` (see `env.example`). With plain `docker run`, pass them with `-e`.

| Variable | Default | Description |
|---|---|---|
| `SINGBOX_PORTS` | `1080-1081` | **Primary knob.** Host:container port range of the SOCKS5 exits; the tunnel count is derived from it (`1080-1082` → 3 tunnels on 1080/1081/1082). |
| `SINGBOX_TUNNELS` | `1` | Number of WARP tunnels / SOCKS5 ports. Only used when `SINGBOX_PORTS` is unset (plain `docker run`). |
| `SINGBOX_SOCKS_PORT` | `1080` | Base SOCKS5 port; tunnels use `1080 .. 1080+N-1`. Only used when `SINGBOX_PORTS` is unset. |
| `WARP_SLEEP` | `2` | Seconds to wait after startup / reload for the tunnels to handshake. |
| `WARP_IP_ROTATE_INTERVAL` | unset | If set, re-register all tunnels periodically and hot-reload. |
| `WARP_LICENSE_KEY` | unset | Optional WARP+ license, applied to each new registration. |
| `SINGBOX_DATA_DIR` | `./data-singbox` | Host dir mounted at `/var/lib/singbox-warp` (tunnel identities). Compose-only. |
| `SING_BOX_VERSION` / `SINGBOX_IMAGE` / `SINGBOX_CONTAINER_NAME` / `SINGBOX_RESTART` | … | Compose-only: sing-box release to build, image tag, container name, restart policy. |
| `DATA_DIR` | `/var/lib/singbox-warp` | Where tunnel identities are persisted inside the container. |
| `WARP_API_BASE` / `WARP_CLIENT_VERSION` / `WARP_WG_PORT` | … | Advanced: API endpoint, client version header, WireGuard peer port (2408). |

## How it works

- `entrypoint.sh` registers one Cloudflare device per tunnel (missing ones only), renders `/etc/singbox/config.json`, validates it, starts sing-box, and (optionally) the rotation loop.
- The sing-box config uses the WireGuard **endpoint** model (sing-box ≥ 1.11; the old `wireguard` outbound is removed in 1.13): each tunnel is an `endpoints[].wireguard` entry with `reserved` bytes decoded from the registration's `client_id`, and the endpoint peer address is pinned to the IP returned by Cloudflare (avoids resolving the peer through the tunnel at startup).
- Each SOCKS5 inbound is routed to its own endpoint via a route rule; DNS queries go through tunnel 0.

## Troubleshooting

- **`curl` times out / connection refused**: wait for `WARP_SLEEP` after startup, then check `docker logs warp-singbox`. If the log shows the wireguard endpoint started but no traffic, verify UDP 2408 is reachable from the container.
- **Registration fails at first start**: the container needs HTTPS access to `api.cloudflareclient.com`; check the `[FATAL] failed to register tunnel` line in the logs.
- **`warp=off` or wrong IP on an exit**: the tunnel did not come up — see the log for that endpoint; then run `/usr/local/bin/rotate.sh` to re-register.
- **WARP+ license stops applying after a while**: a WARP+ account allows at most 5 linked devices; each rotation adds one. Remove old devices in the 1.1.1.1 app or drop `WARP_LICENSE_KEY` (free WARP has no device limit).
- **Want completely fresh identities**: stop the container, delete the `data-singbox` directory (or the `tunnel-*.json` files), start again.

## Trade-offs vs. the official-client mode

| | sing-box mode | Official client (main image) |
|---|---|---|
| Tunnels per container | N (one per SOCKS5 port) | 1 |
| Protocol | WireGuard UDP:2408 only | MASQUE by default (more firewall-resistant) |
| Zero Trust / mdm.xml / org policies | ❌ not supported | ✅ supported |
| WARP+ license | ✅ applied per device (5-device limit) | ✅ same limit |
| Prerequisites | none (userspace, no TUN) | TUN + `NET_ADMIN` + device cgroup rule |
| Rotation | re-register all + `SIGHUP` (whole-instance reload, all ports blip) | `rotate-ip.sh` (tunnel-only reconnect, GOST untouched) |

### Caveats

- **Registration rate limits**: every rotation creates one new device per tunnel; keep intervals above a few minutes. Old devices are left on Cloudflare's side and show up in the 1.1.1.1 app.
- **No MASQUE / no Zero Trust**: use the main image if you need either.
- **UDP 2408** must be reachable from the container to `engage.cloudflareclient.com`.

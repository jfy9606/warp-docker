#!/bin/bash
# lib.sh - shared helpers for the sing-box multi-IP mode.
#
# This mode replaces the official WARP client (warp-svc) with a single
# sing-box process running N independent userspace WireGuard tunnels, each
# exposed as its own SOCKS5 port. Registrations are performed against the
# same Cloudflare API that wgcf uses (api.cloudflareclient.com/v0a4005),
# implemented natively so that the client_id / reserved bytes are captured
# (the wgcf binary discards them, but sing-box's wireguard endpoint needs
# them for new registrations).

set -euo pipefail

API_BASE="${WARP_API_BASE:-https://api.cloudflareclient.com/v0a4005}"
CF_CLIENT_VERSION="${WARP_CLIENT_VERSION:-a-6.30-3596}"
DATA_DIR="${DATA_DIR:-/var/lib/singbox-warp}"
CONFIG_FILE="${SINGBOX_CONFIG_FILE:-/etc/singbox/config.json}"
WG_PORT="${WARP_WG_PORT:-2408}"

# Tunnel count and base SOCKS port. Preferred: a single SINGBOX_PORTS range
# ("1080-1082") used both for the compose port mapping and inside the
# container, so there is only one value to keep consistent. Fallback for
# plain `docker run`: the separate SINGBOX_TUNNELS / SINGBOX_SOCKS_PORT.
if [ -n "${SINGBOX_PORTS:-}" ]; then
    start="${SINGBOX_PORTS%%-*}"
    end="${SINGBOX_PORTS##*-}"
    if [ "$start" -ge 1 ] 2>/dev/null && [ "$end" -ge "$start" ] 2>/dev/null; then
        SOCKS_PORT="$start"
        TUNNELS=$((end - start + 1))
    else
        echo "[singbox] SINGBOX_PORTS must look like '1080-1082' (got: '$SINGBOX_PORTS')" >&2
        exit 1
    fi
else
    TUNNELS="${SINGBOX_TUNNELS:-1}"
    SOCKS_PORT="${SINGBOX_SOCKS_PORT:-1080}"
fi

if [ -z "$TUNNELS" ] || [ "$TUNNELS" -lt 1 ] 2>/dev/null; then
    echo "[singbox] SINGBOX_TUNNELS / SINGBOX_PORTS must yield a positive tunnel count" >&2
    exit 1
fi

# log <msg>
log() {
    echo "[singbox] $*"
}

# generate_keypair: sets PRIVATE_KEY / PUBLIC_KEY (base64 WireGuard keys).
generate_keypair() {
    local out
    out=$(sing-box generate wg-keypair)
    PRIVATE_KEY=$(printf '%s\n' "$out" | sed -n 's/^PrivateKey: //p')
    PUBLIC_KEY=$(printf '%s\n' "$out" | sed -n 's/^PublicKey: //p')
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "generate_keypair: failed to parse keypair" >&2
        return 1
    fi
}

# decode_reserved <client_id_base64>: sets RESERVED to a JSON array of bytes.
decode_reserved() {
    local raw bytes
    raw=$(printf '%s' "$1" | base64 -d 2>/dev/null || true)
    bytes=$(printf '%s' "$raw" | od -An -tu1 | tr -s ' ' | sed 's/^ //; s/ /,/g')
    if [ -z "$bytes" ]; then
        RESERVED="[0,0,0]"
    else
        RESERVED="[$bytes]"
    fi
}

# register_tunnel <index>: registers a brand-new WARP device (new identity,
# therefore a new egress IP) and writes $DATA_DIR/tunnel-<index>.json.
register_tunnel() {
    local idx="$1"
    local state="$DATA_DIR/tunnel-$idx.json"
    local tos body resp device_id token license client_id v4 v6 peer_pub endpoint
    local v4arr v6arr addrs

    generate_keypair
    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    body=$(jq -nc --arg key "$PUBLIC_KEY" --arg tos "$tos" \
        '{key: $key, tos: $tos, type: "PC", model: "sing-box"}')

    resp=$(curl -fsS --max-time 30 -X POST "$API_BASE/reg" \
        -H "CF-Client-Version: $CF_CLIENT_VERSION" \
        -H "Content-Type: application/json" \
        -d "$body") || { echo "register_tunnel: POST /reg failed" >&2; return 1; }

    device_id=$(jq -r '.id // empty' <<<"$resp")
    token=$(jq -r '.token // empty' <<<"$resp")
    license=$(jq -r '.account.license // empty' <<<"$resp")
    client_id=$(jq -r '.config.client_id // empty' <<<"$resp")
    v4=$(jq -r '.config.interface.addresses.v4 // empty' <<<"$resp")
    v6=$(jq -r '.config.interface.addresses.v6 // empty' <<<"$resp")
    peer_pub=$(jq -r '.config.peers[0].public_key // empty' <<<"$resp")
    # prefer the IP returned by Cloudflare (the API returns it as
    # "<ip>:0", strip the port); fall back to the hostname. Using an IP
    # avoids resolving the peer through the tunnel itself at startup.
    endpoint=$(jq -r '.config.peers[0].endpoint.v4 // empty' <<<"$resp" | sed 's/:[0-9]*$//')
    [ -n "$endpoint" ] || endpoint=$(jq -r '.config.peers[0].endpoint.host // empty' <<<"$resp")

    if [ -z "$device_id" ] || [ -z "$token" ] || [ -z "$peer_pub" ]; then
        echo "register_tunnel: response missing id/token/peer public key" >&2
        return 1
    fi
    [ -n "$endpoint" ] || endpoint="162.159.192.1"

    decode_reserved "$client_id"

    # optionally bind a WARP+ license (best effort: a WARP+ account allows at
    # most 5 linked devices, so with multi-tunnel + rotation this fills up fast)
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        if curl -fsS --max-time 30 -X PUT "$API_BASE/reg/$device_id/account" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$(jq -nc --arg l "$WARP_LICENSE_KEY" '{license: $l}')" >/dev/null 2>&1; then
            log "tunnel $idx: WARP+ license applied"
        else
            log "[WARN] tunnel $idx: failed to apply license (device limit reached?), continuing as free WARP"
        fi
    fi

    if [ -z "$v4" ]; then
        v4="172.16.0.2"
    fi
    v4arr=$(jq -nc --arg a "$v4" '[$a + "/32"]')
    if [ -n "$v6" ]; then
        v6arr=$(jq -nc --arg a "$v6" '[$a + "/128"]')
    else
        v6arr="[]"
    fi
    addrs=$(jq -nc --argjson v4 "$v4arr" --argjson v6 "$v6arr" '$v4 + $v6')

    jq -nc \
        --arg priv "$PRIVATE_KEY" \
        --argjson addrs "$addrs" \
        --arg peer "$peer_pub" \
        --arg ep "$endpoint" \
        --argjson reserved "$RESERVED" \
        --arg id "$device_id" \
        --arg tok "$token" \
        --arg lic "$license" \
        '{private_key: $priv, address: $addrs, peer_public_key: $peer,
          endpoint: $ep, reserved: $reserved,
          device_id: $id, access_token: $tok, license: $lic}' > "$state"

    log "tunnel $idx registered (device_id=$device_id, endpoint=$endpoint)"
}

# gen_config: renders the sing-box config (socks inbounds, wireguard
# endpoints, route rules) from all state files. Endpoints are outbounds
# themselves in sing-box >= 1.11, so route rules reference endpoint tags
# directly (see adapter/outbound/manager.go in the sing-box source).
gen_config() {
    local files=() i
    for ((i = 0; i < TUNNELS; i++)); do
        local state="$DATA_DIR/tunnel-$i.json"
        if [ ! -f "$state" ]; then
            echo "gen_config: missing state file $state" >&2
            return 1
        fi
        files+=("$state")
    done

    jq -s --argjson base "$SOCKS_PORT" --argjson wgport "$WG_PORT" '
        to_entries as $all |
        {
          log: {level: "info"},
          dns: {
            servers: [
              {type: "udp", tag: "cf", server: "1.1.1.1",
               detour: "wg-0"}
            ]
          },
          inbounds: [$all[] | .key as $i | {
            type: "socks",
            tag: ("socks-" + ($i | tostring)),
            listen: "0.0.0.0",
            listen_port: ($base + $i)
          }],
          endpoints: [$all[] | .key as $i | {
            type: "wireguard",
            tag: ("wg-" + ($i | tostring)),
            system: false,
            address: .value.address,
            private_key: .value.private_key,
            peers: [{
              address: .value.endpoint,
              port: $wgport,
              public_key: .value.peer_public_key,
              allowed_ips: ["0.0.0.0/0", "::/0"],
              reserved: .value.reserved
            }]
          }],
          route: {
            default_domain_resolver: {server: "cf"},
            rules: [$all[] | .key as $i | {
              inbound: ("socks-" + ($i | tostring)),
              outbound: ("wg-" + ($i | tostring))
            }],
            final: "wg-0"
          }
        }
    ' "${files[@]}" > "$CONFIG_FILE"
    log "generated $CONFIG_FILE ($TUNNELS tunnel(s), socks ports $SOCKS_PORT..$((SOCKS_PORT + TUNNELS - 1)))"
}

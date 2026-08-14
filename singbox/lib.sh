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
#
# Optional chaining: set WARP_PROXY=socks5://[user:pass@]host:port to dial
# the WireGuard tunnels through an upstream SOCKS5 proxy (WireGuard ->
# SOCKS5 -> Cloudflare). Each wireguard endpoint gets a "detour" to a socks
# outbound, and every API call (registration, license, rotation) goes
# through the same proxy.

set -euo pipefail

API_BASE="${WARP_API_BASE:-https://api.cloudflareclient.com/v0a4005}"
CF_CLIENT_VERSION="${WARP_CLIENT_VERSION:-a-6.30-3596}"
DATA_DIR="${DATA_DIR:-/var/lib/singbox-warp}"
CONFIG_FILE="${SINGBOX_CONFIG_FILE:-/etc/singbox/config.json}"
WG_PORT="${WARP_WG_PORT:-2408}"

# urldecode <str>: minimal percent-decoding (e.g. for user/pass in the proxy
# URL). Literal backslashes are escaped first so printf does not mangle them.
urldecode() {
    local s="${1//\\/\\\\}"
    printf '%b' "${s//%/\\x}"
}

# is_ip <host>: true if <host> looks like an IPv4 or IPv6 address (no DNS
# resolution needed, no network access).
is_ip() {
    local s="$1"
    if [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$s" == *":"* ]] && [[ "$s" =~ ^[0-9a-fA-F:]+$ ]]; then
        return 0
    fi
    return 1
}

# parse_proxy_url <url> <mode>: parses a SOCKS5 proxy URL of the form
#   socks5://[user:pass@]host:port[?udp_over_tcp=true]
# (socks:// and socks5h:// are accepted as aliases) and sets PROXY_HOST /
# PROXY_PORT / PROXY_USER / PROXY_PASS / PROXY_HOSTNAME / PROXY_UDP_OVER_TCP /
# PROXY_URL (the same URL with the query string stripped, for tools like GOST
# that must not see sing-box-only query parameters). Returns non-zero on
# malformed input.
parse_proxy_url() {
    local url="$1" mode="$2" userinfo rest portnum
    PROXY_HOST= PROXY_PORT= PROXY_USER= PROXY_PASS= PROXY_HOSTNAME= PROXY_UDP_OVER_TCP=0 PROXY_URL=

    case "$url" in
        socks5://*|socks://*|socks5h://*) url="${url#*://}" ;;
        *)
            echo "[$mode] WARP_PROXY must be a socks5:// URL, e.g. socks5://user:pass@host:1080 (got: '$url')" >&2
            return 1
            ;;
    esac

    # strip the query string (sing-box only options like ?udp_over_tcp=true)
    if [[ "$url" == *"?"* ]]; then
        local query="${url##*\?}"
        url="${url%%\?*}"
        case ",$query," in
            *,udp_over_tcp=true,*) PROXY_UDP_OVER_TCP=1 ;;
        esac
    fi
    PROXY_URL="socks5://$url"

    # userinfo
    if [[ "$url" == *"@"* ]]; then
        userinfo="${url%%@*}"
        url="${url#*@}"
        PROXY_USER="$(urldecode "${userinfo%%:*}")"
        if [[ "$userinfo" == *":"* ]]; then
            PROXY_PASS="$(urldecode "${userinfo#*:}")"
        fi
    fi

    # host:port (IPv6 must be bracketed: [::1]:1080)
    if [[ "$url" == \[*\]* ]]; then
        PROXY_HOST="${url%%]*}"
        PROXY_HOST="${PROXY_HOST#[}"
        rest="${url#*]}"
        PROXY_PORT="${rest#:}"
    else
        PROXY_HOST="${url%%:*}"
        PROXY_PORT="${url#*:}"
    fi

    if [ -z "$PROXY_HOST" ]; then
        echo "[$mode] WARP_PROXY is missing the proxy host" >&2
        return 1
    fi
    if [ -z "$PROXY_PORT" ] || ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
        echo "[$mode] WARP_PROXY is missing a numeric port (got: '$PROXY_PORT')" >&2
        return 1
    fi
    portnum=$((10#$PROXY_PORT))
    if [ "$portnum" -lt 1 ] || [ "$portnum" -gt 65535 ]; then
        echo "[$mode] WARP_PROXY port out of range: $PROXY_PORT" >&2
        return 1
    fi
    if ! is_ip "$PROXY_HOST"; then
        # hostname: must be resolved outside the tunnel (see gen_config),
        # otherwise resolving the proxy through the tunnel is circular
        PROXY_HOSTNAME="$PROXY_HOST"
    fi
}

# ---- optional upstream SOCKS5 proxy (WARP_PROXY) ----
# Format: socks5://[user:pass@]host:port[?udp_over_tcp=true].
PROXY_ENABLED=0
PROXY_HOST=
PROXY_PORT=
PROXY_USER=
PROXY_PASS=
PROXY_HOSTNAME=
PROXY_UDP_OVER_TCP=0
if [ -n "${WARP_PROXY:-}" ]; then
    if ! parse_proxy_url "$WARP_PROXY" "singbox"; then
        exit 1
    fi
    PROXY_ENABLED=1
fi

# curl is wrapped so that every Cloudflare API call (registration, license
# binding, device deletion at rotation) goes through the upstream proxy too -
# in a network where the proxy is required, the container otherwise could not
# register at all. CURL_PROXY_ARGS is empty when the proxy is disabled.
CURL_PROXY_ARGS=()
if [ "$PROXY_ENABLED" -eq 1 ]; then
    local_hostport="$PROXY_HOST:$PROXY_PORT"
    if [[ "$PROXY_HOST" == *":"* ]]; then
        # IPv6 needs brackets: [::1]:1080
        local_hostport="[$PROXY_HOST]:$PROXY_PORT"
    fi
    CURL_PROXY_ARGS+=(--socks5-hostname "$local_hostport")
    if [ -n "$PROXY_USER" ]; then
        CURL_PROXY_ARGS+=(-U "$PROXY_USER:$PROXY_PASS")
    fi
fi
curl() {
    command curl "${CURL_PROXY_ARGS[@]}" "$@"
}

# resolve_proxy_host <mode>: resolves PROXY_HOSTNAME (a non-IP proxy host)
# to an IP using the container's own DNS, which is outside the tunnel
# (WireGuard runs in userspace, so the system resolver never traverses it).
# Sets PROXY_HOST to the resolved IP. Prefers IPv4. Called from gen_config,
# so the hostname is re-resolved on every rotation as well.
resolve_proxy_host() {
    local mode="$1" ip=""
    [ -n "${PROXY_HOSTNAME:-}" ] || return 0
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent ahostsv4 "$PROXY_HOSTNAME" 2>/dev/null | awk 'NR==1{print $1; exit}')
        [ -n "$ip" ] || ip=$(getent ahostsv6 "$PROXY_HOSTNAME" 2>/dev/null | awk 'NR==1{print $1; exit}')
        [ -n "$ip" ] || ip=$(getent hosts "$PROXY_HOSTNAME" 2>/dev/null | awk 'NR==1{print $1; exit}')
    fi
    if [ -z "$ip" ]; then
        echo "[$mode] WARP_PROXY: cannot resolve proxy hostname '$PROXY_HOSTNAME' (DNS must be reachable from the container, outside the tunnel). Put an IP in WARP_PROXY to skip resolution." >&2
        return 1
    fi
    log "$mode: proxy hostname $PROXY_HOSTNAME resolved to $ip"
    PROXY_HOST="$ip"
}

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

# delete_device <device_id> <access_token>: best-effort deletion of a WARP
# device on Cloudflare's side. Rotation otherwise leaks one device per cycle:
# old identities pile up forever, exhausting WARP+ quotas and inviting
# Cloudflare rate-limiting. Failure is non-fatal (logged as a warning).
delete_device() {
    local id="$1" tok="$2"
    [ -n "$id" ] && [ -n "$tok" ] || return 0
    if curl -sS --max-time 20 -o /dev/null -X DELETE \
        -H "Authorization: Bearer $tok" \
        "$API_BASE/reg/$id"; then
        log "deleted old device $id"
    else
        log "[WARN] could not delete old device $id (ignored)"
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
#
# When WARP_PROXY is set, each wireguard endpoint gets "detour": "socks-out"
# (the endpoint's underlying UDP socket is dialed through the socks outbound,
# i.e. WireGuard -> SOCKS5 -> Cloudflare) and a socks outbound is added to
# the config. The proxy hostname is resolved to an IP here, outside the
# tunnel, so sing-box never has to resolve the proxy through the tunnel
# itself (which would be circular).
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

    if [ "$PROXY_ENABLED" -eq 1 ]; then
        if ! resolve_proxy_host "singbox"; then
            return 1
        fi
        log "WARP tunnels will be chained through socks5://$PROXY_HOST:$PROXY_PORT"
    fi

    jq -s --argjson base "$SOCKS_PORT" --argjson wgport "$WG_PORT" \
        --argjson proxy "$PROXY_ENABLED" \
        --arg proxyhost "${PROXY_HOST:-}" \
        --argjson proxyport "${PROXY_PORT:-0}" \
        --arg proxyuser "${PROXY_USER:-}" \
        --arg proxypass "${PROXY_PASS:-}" \
        --argjson udpOverTcp "$PROXY_UDP_OVER_TCP" '
        to_entries as $all |
        ($proxy == 1) as $useProxy |
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
          } + (if $useProxy then {detour: "socks-out"} else {} end)],
          outbounds: (if $useProxy then [
            ({type: "socks", tag: "socks-out", server: $proxyhost,
              server_port: $proxyport, version: "5",
              udp_over_tcp: (if $udpOverTcp == 1 then {} else false end)}
             + (if $proxyuser != "" then
                  {username: $proxyuser, password: $proxypass}
                else {} end))
          ] else [] end),
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

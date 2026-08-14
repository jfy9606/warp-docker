#!/bin/bash
# entrypoint.sh - sing-box multi-IP mode entry point.
#
# Registers a WARP tunnel per SOCKS5 port (if not yet persisted), generates
# the sing-box config, validates it, and runs sing-box in the foreground.
# When WARP_IP_ROTATE_INTERVAL is set, a background loop re-registers all
# tunnels and SIGHUPs sing-box to hot-reload the new config.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

log "sing-box multi-IP mode: tunnels=$TUNNELS, socks base port=$SOCKS_PORT${PROXY_ENABLED:+, WARP_PROXY=$PROXY_HOST:$PROXY_PORT}"

mkdir -p "$DATA_DIR"

# register tunnels that do not have a persisted identity yet
for ((i = 0; i < TUNNELS; i++)); do
    if [ ! -f "$DATA_DIR/tunnel-$i.json" ]; then
        log "registering tunnel $i ..."
        if ! register_tunnel "$i"; then
            log "[FATAL] failed to register tunnel $i" >&2
            exit 1
        fi
    fi
done

gen_config || { log "[FATAL] failed to generate sing-box config" >&2; exit 1; }
if ! sing-box check -c "$CONFIG_FILE"; then
    log "[FATAL] generated sing-box config is invalid" >&2
    exit 1
fi

if [ -n "${WARP_IP_ROTATE_INTERVAL:-}" ]; then
    log "IP rotation enabled, re-registering every $WARP_IP_ROTATE_INTERVAL (all tunnels at once, one reload)"
    (
        while true; do
            sleep "$WARP_IP_ROTATE_INTERVAL"
            "$SCRIPT_DIR/rotate.sh" \
                || log "[WARN] rotation failed, will retry in the next cycle"
        done
    ) &
fi

# give the tunnels a moment to complete their first handshake (same env var
# as the official-client mode; default 2 seconds)
sleep "${WARP_SLEEP:-2}"

log "starting sing-box"
exec sing-box run -c "$CONFIG_FILE"

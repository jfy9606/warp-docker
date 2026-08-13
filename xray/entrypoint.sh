#!/bin/bash
# entrypoint.sh - xray multi-IP mode entry point.
#
# Registers a WARP tunnel per SOCKS5 port (if not yet persisted), generates
# the xray config, validates it, and runs xray in the foreground. xray has
# no SIGHUP hot reload, so it runs inside a small restart loop: rotations
# (re-register all tunnels + regenerate the config) kill the process and the
# loop brings it back up with the new config. SIGTERM is forwarded to xray
# so `docker stop` stays fast and clean.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

log "xray multi-IP mode: tunnels=$TUNNELS, socks base port=$SOCKS_PORT"

# forward TERM/INT to the running xray and exit (keeps `docker stop` clean)
XRAY_CHILD=
term_handler() {
    log "received SIGTERM, stopping xray"
    if [ -n "$XRAY_CHILD" ]; then
        kill -TERM "$XRAY_CHILD" 2>/dev/null || true
        wait "$XRAY_CHILD" 2>/dev/null || true
    fi
    exit 0
}
trap term_handler TERM INT

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

gen_config || { log "[FATAL] failed to generate xray config" >&2; exit 1; }
if ! xray run -test -c "$CONFIG_FILE"; then
    log "[FATAL] generated xray config is invalid" >&2
    exit 1
fi

if [ -n "${WARP_IP_ROTATE_INTERVAL:-}" ]; then
    log "IP rotation enabled, re-registering every $WARP_IP_ROTATE_INTERVAL (all tunnels at once, one restart)"
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

log "starting xray"
while true; do
    xray run -c "$CONFIG_FILE" &
    XRAY_CHILD=$!
    if wait "$XRAY_CHILD"; then
        log "xray exited cleanly; restarting"
    else
        code=$?
        log "[WARN] xray exited with code $code; restarting"
    fi
    sleep 1
done

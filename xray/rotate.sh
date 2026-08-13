#!/bin/bash
# rotate.sh - re-register all WARP tunnels and restart xray.
#
# Every tunnel gets a brand-new identity (and therefore a new egress IP),
# the xray config is regenerated and validated, and the running xray
# process is restarted to apply it (xray has no SIGHUP hot reload; the
# entrypoint restart loop brings it back up with the new config). Restart
# is skipped if any registration or the config check fails, so a broken
# cycle never takes down the running tunnels.
#
# Note: xray recreates the whole instance on restart (all outbounds +
# inbounds), so all SOCKS5 ports blip briefly at each rotation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

log "rotating all $TUNNELS tunnel(s) ..."

for ((i = 0; i < TUNNELS; i++)); do
    state="$DATA_DIR/tunnel-$i.json"
    old_id=$(jq -r '.device_id // "?"' "$state" 2>/dev/null || echo "?")
    old_tok=$(jq -r '.access_token // ""' "$state" 2>/dev/null || echo "")
    if register_tunnel "$i"; then
        new_id=$(jq -r '.device_id' "$state")
        log "tunnel $i: $old_id -> $new_id"
        # delete the replaced device on Cloudflare's side so old identities
        # don't pile up (quota + rate-limiting). Non-fatal on failure.
        delete_device "$old_id" "$old_tok"
    else
        log "[WARN] tunnel $i rotation failed, keeping the old config and skipping restart"
        exit 1
    fi
done

gen_config || { log "[WARN] failed to regenerate config, keeping old one"; exit 1; }
if ! xray run -test -c "$CONFIG_FILE"; then
    log "[WARN] new config is invalid, keeping the old one"
    exit 1
fi

pid=$(pgrep -f "xray run" || true)
if [ -n "$pid" ]; then
    log "restarting xray (pid $pid) to apply the new config"
    kill "$pid"
    # the entrypoint restart loop sleeps 1s between runs; wait for xray to
    # come back up with the new config (a NEW pid)
    for _ in $(seq 1 10); do
        sleep 1
        alive=$(pgrep -f "xray run" || true)
        if [ -n "$alive" ] && [ "$alive" != "$pid" ]; then
            log "xray restarted (pid $alive)"
            break
        fi
    done
else
    log "[WARN] xray is not running; new config will be used at next start"
fi
sleep "${WARP_SLEEP:-2}"
log "rotation done"

#!/bin/bash
# rotate.sh - re-register all WARP tunnels and hot-reload sing-box.
#
# Every tunnel gets a brand-new identity (and therefore a new egress IP),
# the sing-box config is regenerated and validated, and the running
# sing-box process is told to reload via SIGHUP. Reload is skipped if any
# registration or the config check fails, so a broken cycle never takes
# down the running tunnels.
#
# Note: sing-box reloads the whole instance (all endpoints + inbounds are
# recreated), so all SOCKS5 ports blip briefly at each rotation.

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
        log "[WARN] tunnel $i rotation failed, keeping the old config and skipping reload"
        exit 1
    fi
done

gen_config || { log "[WARN] failed to regenerate config, keeping old one"; exit 1; }
if ! sing-box check -c "$CONFIG_FILE"; then
    log "[WARN] new config is invalid, keeping the old one"
    exit 1
fi

pid=$(pgrep -f "sing-box run" || true)
if [ -n "$pid" ]; then
    log "reloading sing-box (pid $pid)"
    kill -HUP "$pid"
    sleep "${WARP_SLEEP:-2}"
    log "rotation done"
else
    log "[WARN] sing-box is not running; new config will be used at next start"
fi

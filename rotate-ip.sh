#!/bin/bash

# rotate-ip.sh - force a new WARP IP.
#
# Deleting the registration and creating a new one assigns a brand new
# identity (and therefore a new IP) to the client. This is triggered
# periodically by entrypoint.sh when WARP_IP_ROTATE_INTERVAL is set.
#
# Caveats:
# - With WARP_LICENSE_KEY set, every rotation links a new device to the
#   account. WARP+ accounts allow up to 5 linked devices; once the limit is
#   reached the license can no longer be applied and the client falls back to
#   regular (free) WARP. Remove old devices in the 1.1.1.1 app if needed.
# - With Zero Trust (mdm.xml present), re-registering would break the
#   enrollment, so the script falls back to a plain reconnect, which may or
#   may not change the IP.

# exit when any command fails
set -e

echo "[IP Rotation] Starting rotation..."

# if mdm.xml exists and REGISTER_WHEN_MDM_EXISTS is empty, re-registering would
# break the Zero Trust enrollment, so only reconnect (same logic as entrypoint.sh)
if [ -f /var/lib/cloudflare-warp/mdm.xml ] && [ -z "$REGISTER_WHEN_MDM_EXISTS" ]; then
    echo "[IP Rotation] mdm.xml found (Zero Trust), only reconnecting instead of re-registering."
    warp-cli --accept-tos disconnect || true
    sleep "$WARP_SLEEP"
    warp-cli --accept-tos connect
    echo "[IP Rotation] Reconnected."
    exit 0
fi

# current IP, for logging only (may be empty if the tunnel is briefly down)
old_ip=$(curl -fsS https://cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)

warp-cli --accept-tos disconnect

# delete the current registration and its state file to force a new identity
warp-cli --accept-tos registration delete || true
rm -f /var/lib/cloudflare-warp/reg.json

# register a new identity (retry once if the daemon still holds the old one)
if ! warp-cli --accept-tos registration new; then
    echo "[IP Rotation] Registration failed, deleting old registration and retrying..."
    warp-cli --accept-tos registration delete || true
    warp-cli --accept-tos registration new
fi

# re-apply the license key if provided (best-effort: the account may have
# reached its device limit, in which case the client keeps working as free WARP)
if [ -n "$WARP_LICENSE_KEY" ]; then
    echo "[IP Rotation] Re-applying license key..."
    warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" \
        || echo "[IP Rotation] [WARN] Failed to apply license key (device limit reached?). Skipped."
fi

# use MASQUE as the default tunnel protocol (same as entrypoint.sh)
warp-cli --accept-tos tunnel protocol set MASQUE \
    || echo "[IP Rotation] [WARN] Failed to set tunnel protocol to MASQUE, skipped."

# reconnect (retry once to survive transient failures)
if ! warp-cli --accept-tos connect; then
    echo "[IP Rotation] Connect failed, retrying..."
    sleep "$WARP_SLEEP"
    warp-cli --accept-tos connect
fi

# wait for the connection to come up
sleep "$WARP_SLEEP"

new_ip=$(curl -fsS https://cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)
echo "[IP Rotation] Done. IP changed from '$old_ip' to '$new_ip'."

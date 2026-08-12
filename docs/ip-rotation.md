# IP rotation

The container can periodically force a new WARP IP by re-registering the WARP client. A newly registered identity is always assigned a fresh IP by Cloudflare.

## Enable

Set `WARP_IP_ROTATE_INTERVAL` in the `docker-compose.yml`. The value is passed directly to GNU `sleep`, so it can be a plain number of seconds or a duration with a suffix:

```yaml
environment:
  - WARP_IP_ROTATE_INTERVAL=6h   # every 6 hours
```

Examples: `3600` (1 hour), `30m` (30 minutes), `12h` (12 hours). When unset (default), rotation is disabled.

## How it works

At each interval, a background loop in the container runs `rotate-ip.sh`, which:

1. disconnects the client;
2. deletes the current registration (`warp-cli registration delete`) and removes `reg.json`;
3. registers a new identity (`warp-cli registration new`);
4. re-applies `WARP_LICENSE_KEY` if set;
5. sets the tunnel protocol back to MASQUE (best-effort, same as at startup);
6. reconnects and waits for the tunnel to come up.

A failed rotation is logged and retried at the next interval; the container keeps running.

## Caveats

- **Brief downtime**: the proxy keeps listening on port 1080 during the rotation, but traffic cannot pass through the tunnel for a few seconds while it reconnects. Long-lived connections (e.g. established TCP sessions) are dropped.
- **WARP+ device limit**: every rotation links a *new* device to the account bound to `WARP_LICENSE_KEY`. A WARP+ account allows up to 5 linked devices; once the limit is reached, applying the license fails and the client keeps working as regular (free) WARP. Remove old devices in the 1.1.1.1 app to free up slots. If you do not set `WARP_LICENSE_KEY`, rotation is unlimited.
- **Zero Trust**: re-registering would break a Zero Trust enrollment, so when `mdm.xml` exists (and `REGISTER_WHEN_MDM_EXISTS` is not set) the rotation falls back to a plain disconnect/reconnect, which may or may not yield a new IP.
- **Registration spam**: creating many registrations in a short time may be rate-limited by Cloudflare, so avoid very short intervals (less than a few minutes).

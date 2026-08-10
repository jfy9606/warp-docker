# MASQUE

[MASQUE](https://blog.cloudflare.com/zero-trust-warp-with-a-masque/) is WARP's new protocol which is more unlikely to be block by firewall (of your company or ISP) than WireGuard.

## Default tunnel protocol

In this repository, MASQUE is set as the default tunnel protocol by the entrypoint (`warp-cli tunnel protocol set MASQUE`). No manual steps are needed.

The setting is applied on every container start, but failures are tolerated: for Zero Trust accounts the tunnel protocol may be enforced by the organization (via `mdm.xml` / the Zero Trust portal's [device tunnel protocol](https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/configure-warp/warp-settings/#device-tunnel-protocol) setting), in which case the command fails and is skipped.

## Manual steps (if you need to change it)

If you want to revert to WireGuard, get into the container shell and run:

1. run `docker exec -it warp bash` to get into the container shell
2. run `warp-cli tunnel protocol set WIREGUARD` to switch back to WireGuard
3. run `warp-cli settings list` to check if the change is applied

## QLog

By default, QLog is disabled in the image due to [a known issue that it will generate a large amount of logs](https://www.reddit.com/r/CloudFlare/comments/1g6h9rt/what_are_qlogs/). If you want to enable QLog, you can pass `DEBUG_ENABLE_QLOG=true` to the container.
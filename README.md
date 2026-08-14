# warp-docker

Run official [Cloudflare WARP](https://1.1.1.1/) client in Docker.

> [!WARNING]
> Unlike the upstream project [cmj2002/warp-docker](https://github.com/cmj2002/warp-docker),
> this repository does not publish pre-built images. Do **not** use the upstream
> image `caomingjun/warp` with the configuration below, since it does not
> contain the modifications made in this repository. Build and run your own
> image instead, as described in [Usage](#usage).

## Differences from upstream

- **MASQUE by default**: the WARP tunnel protocol is set to [MASQUE](https://blog.cloudflare.com/zero-trust-warp-with-a-masque/) at container startup, which is less likely to be blocked by firewalls than the traditional WireGuard protocol.
- **GOST v3**: the bundled [GOST](https://github.com/go-gost/gost) is upgraded from v2 (which is no longer maintained) to v3, enabling new features such as the [ICMP tunnel](https://gost.run/en/tutorials/icmp/) for proxying ICMP-like traffic.
- **Smaller image**: the image is based on `debian:trixie-slim` (Debian 13, Cloudflare officially supports Debian) and the WARP GUI packages that are not needed in a headless container are stripped out, reducing the image size from ~900MB to ~420MB.

## Usage

### Build the image

The `GOST_VERSION` and the WARP client version (always the latest from Cloudflare's apt repository) are selected at build time:

```bash
docker build --build-arg GOST_VERSION=3.2.6 -t warp-docker:latest .
```

### Start the container

The repository ships a ready-to-use `docker-compose.yml` which builds the image locally. Just run:

```bash
docker compose up -d --build
```

The equivalent `docker-compose.yml` is:

```yaml
services:
  warp:
    build:
      context: .
      args:
        GOST_VERSION: 3.2.6
    image: warp-docker:latest
    container_name: warp
    restart: always
    # add removed rule back (https://github.com/opencontainers/runc/pull/3468)
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=2
      # - WARP_LICENSE_KEY= # optional
      # - WARP_ENABLE_NAT=1 # enable nat
    cap_add:
      # Docker already have them, these are for podman users
      - MKNOD
      - AUDIT_WRITE
      # additional required cap for warp, both for podman and docker
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      # uncomment for nat
      # - net.ipv4.ip_forward=1
      # - net.ipv6.conf.all.forwarding=1
      # - net.ipv6.conf.all.accept_ra=2
    volumes:
      - ./data:/var/lib/cloudflare-warp
```

Alternatively, run it directly with `docker run`:

```bash
docker run -d --name warp \
  --device-cgroup-rule 'c 10:200 rwm' \
  --cap-add MKNOD --cap-add AUDIT_WRITE --cap-add NET_ADMIN \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -p 1080:1080 \
  -e WARP_SLEEP=2 \
  -v ./data:/var/lib/cloudflare-warp \
  warp-docker:latest
```

### Verify

```bash
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
```

If the output contains `warp=on` or `warp=plus`, the container is working properly. If the output contains `warp=off`, it means that the container failed to connect to the WARP service.

### Configuration

You can configure the container through the following environment variables:

- `WARP_SLEEP`: The time to wait for the WARP daemon to start, in seconds. The default is 2 seconds. If the time is too short, it may cause the WARP daemon to not start before using the proxy, resulting in the proxy not working properly. If the time is too long, it may cause the container to take too long to start. If your server has poor performance, you can increase this value appropriately.
- `WARP_LICENSE_KEY`: The license key of the WARP client, which is optional. If you have subscribed to WARP+ service, you can fill in the key in this environment variable. If you have not subscribed to WARP+ service, you can ignore this environment variable.
- `GOST_ARGS`: The arguments passed to GOST (v3). The default is `-L :1080`, which means to listen on port 1080 in the container at the same time through HTTP and SOCKS5 protocols. If you want to have UDP support or use advanced features provided by other protocols, you can modify this parameter. For more information, refer to [GOST documentation](https://gost.run/en/). If you modify the port number, you may also need to modify the port mapping in the `docker-compose.yml`.
- `REGISTER_WHEN_MDM_EXISTS`: If set, will register consumer account (WARP or WARP+, in contrast to Zero Trust) even when `mdm.xml` exists. You usually don't need this, as `mdm.xml` are usually used for Zero Trust. However, some users may want to adjust advanced settings in `mdm.xml` while still using consumer account.
- `BETA_FIX_HOST_CONNECTIVITY`: If set, will add checks for host connectivity into healthchecks and automatically fix it if necessary. See [host connectivity issue](docs/host-connectivity.md) for more information.
- `WARP_ENABLE_NAT`: If set, will work as warp mode and turn NAT on. You can route L3 traffic through `warp-docker` to Warp. See [nat gateway](docs/nat-gateway.md) for more information.
- `WARP_IP_ROTATE_INTERVAL`: If set, the container will periodically force a new WARP IP by re-registering the client. The value is passed to GNU `sleep`, so it can be a number of seconds (e.g. `3600`) or a duration like `30m` / `6h`. Traffic through the proxy is briefly interrupted at each rotation. See [IP rotation](docs/ip-rotation.md) for more information and caveats.

> [!NOTE]
> The tunnel protocol is set to MASQUE by default at startup. The failure of
> setting it is tolerated, because the protocol may be enforced by the
> organization via `mdm.xml` / Zero Trust policies. See [masque](docs/masque.md)
> for more details.

Data persistence: Use the host volume `./data` to persist the data of the WARP client. You can change the location of this directory or use other types of volumes. If you modify the `WARP_LICENSE_KEY`, please delete the `./data` directory so that the client can detect and register again.

### Rotate the WARP IP periodically

To get a fresh WARP IP on a schedule, set `WARP_IP_ROTATE_INTERVAL` in the `docker-compose.yml`:

```yaml
environment:
  - WARP_IP_ROTATE_INTERVAL=6h
```

Every interval, the container deletes its registration, registers a new identity (which always gets a new IP) and reconnects. The proxy keeps listening during the rotation, but traffic is briefly interrupted while the tunnel reconnects. See [IP rotation](docs/ip-rotation.md) for caveats (WARP+ device limit, Zero Trust).

### Alternative: sing-box / xray multi-IP mode (N exits, one container)

This repository also ships **two separate, optional modes** that replace the official client with [sing-box](https://sing-box.sagernet.org/) or [Xray-core](https://github.com/XTLS/Xray-core): one container runs N independent WARP tunnels, each exposed as its own SOCKS5 port (N independent egress IPs), with IP rotation done by re-registering — no TUN device or `NET_ADMIN` needed (both run WireGuard in userspace).

- **sing-box mode** (`docker-compose.singbox.yml`): lighter binary and RAM, rotation hot-reloads via `SIGHUP` (no process restart). See [sing-box multi-IP mode](docs/singbox-multi-ip.md).
- **xray mode** (`docker-compose.xray.yml`): slightly heavier, but ships device cleanup on Cloudflare's side at rotation and official-client MTU/keepalive. See [xray multi-IP mode](docs/xray-multi-ip.md).

Both are driven by the same `.env` file — no need to edit the compose file:

```bash
cp env.example .env          # adjust SINGBOX_PORTS / XRAY_PORTS, ...
docker compose -f docker-compose.singbox.yml up -d --build   # or: -f docker-compose.xray.yml
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
curl --socks5-hostname 127.0.0.1:1081 https://cloudflare.com/cdn-cgi/trace
```

`SINGBOX_PORTS` / `XRAY_PORTS` is the single knob per mode controlling the exits: `1080-1081` runs 2 tunnels, `1080-1082` runs 3, etc. Both modes also accept `WARP_PROXY=socks5://[user:pass@]host:port` to chain the WireGuard tunnels through an upstream SOCKS5 proxy (`WireGuard -> SOCKS5 -> Cloudflare`) — supported by sing-box (endpoint `detour`) and xray (`proxySettings`), **not** by the official client. See [env.example](env.example), [docs/singbox-multi-ip.md](docs/singbox-multi-ip.md) and [docs/xray-multi-ip.md](docs/xray-multi-ip.md) for every option and caveats.

> [!WARNING]
> Both multi-IP modes are **experimental**: Cloudflare restricts API-registered WireGuard devices, so sessions can degrade or drop within minutes. The official-client mode (main `docker-compose.yml`) is the reliable path for production traffic.

For advanced usage or configurations, see [documentation](docs/README.md).

## Build

You can use Github Actions to build the image and push it to your own registry.

1. Fork this repository.
2. Create necessary variables and secrets in the repository settings:
   1. variable `REGISTRY`: for example, `docker.io` (Docker Hub)
   2. variable `IMAGE_NAME`: your image name
   3. variable `DOCKER_USERNAME`: your registry username
   4. secret `DOCKER_PASSWORD`: your registry token
3. Manually trigger the workflow `Build and push image` in the Actions tab.

The workflow resolves the latest stable GOST v3 release automatically; you can also specify the GOST version by giving input to the workflow. The WARP client version is always the latest available in Cloudflare's apt repository.

## Common problems

### Proxying UDP or even ICMP traffic

The default `GOST_ARGS` is `-L :1080`, which provides HTTP and SOCKS5 proxy. If you want to proxy UDP or even ICMP traffic, you need to change the `GOST_ARGS`. Read the [GOST documentation](https://gost.run/en/) for more information. If you modify the port number, you may also need to modify the port mapping in the `docker-compose.yml`.

Traffic that cannot be carried by SOCKS5, like ICMP, can be tunneled using GOST's ICMP tunnel (a GOST v3 feature, not available in v2). The container acts as the server end of the tunnel; run GOST on your local machine as the client:

```yaml
environment:
  - GOST_ARGS="-L :1080 -L relay+icmp://:0"
```

```bash
# on your local machine, <server_ip> is the IP of the warp container
gost -L :8080 -F "relay+icmp://<server_ip>:12345?keepalive=true&ttl=10s"
```

Your local traffic is then encapsulated in ICMP echo (ping) packets, travels to the server and exits through WARP. Note that GOST identifies clients by IP plus the ICMP Identifier (set via the port in the example above), and an ICMP channel can only be used as the first hop of a forwarding chain. See the [ICMP tunnel documentation](https://gost.run/en/tutorials/icmp/) for more details.

### How to connect from another container

You may want to use the proxy from another container and find that you cannot connect to `127.0.0.1:1080` in that container. This is because the `docker-compose.yml` only maps the port to the host, not to other containers. To solve this problem, you can use the service name as the hostname, for example, `warp:1080`. You also need to put the two containers in the same docker network.

### "Operation not permitted" when open tun

Error like `{ err: Os { code: 1, kind: PermissionDenied, message: "Operation not permitted" }, context: "open tun" }` is caused by [a updated of containerd](https://github.com/containerd/containerd/releases/tag/v1.7.24). You need to pass the tun device to the container following the [instruction](docs/tun-not-permitted.md).

### NFT error on Synology or QNAP NAS

If you are using Synology or QNAP NAS, you may encounter an error like `Failed to run NFT command`. This is because both Synology and QNAP use old iptables, while WARP uses nftables. It can't be easily fixed since nftables need to be added when the kernel is compiled.

Possible solutions:
- If you don't need UDP support, use the WARP's proxy mode by following the instructions in the [documentation](docs/proxy-mode.md).
- If you need UDP support, run a fully virtualized Linux system (KVM) on your NAS or use another device to run the container.

References that might help:
- [Related issue](https://github.com/cmj2002/warp-docker/issues/16)
- [Request of supporting iptables in Cloudflare Community](https://community.cloudflare.com/t/legacy-support-for-docker-containers-running-on-synology-qnap/733983)

### Container runs well but cannot connect from host

This issue often arises when using Zero Trust. You may find that you can run `curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace` inside the container, but cannot run this command outside the container (from host or another container). This is because Cloudflare WARP client is grabbing the traffic. See [host connectivity issue](docs/host-connectivity.md) for solutions.

### How to enable MASQUE / use with Zero Trust / set up WARP Connector / change health check parameters

See [documentation](docs/README.md).

### Permission issue when using Podman

See [documentation](docs/podman.md) for explaination and solution.

## Further reading

For how it works, read the [blog post](https://blog.caomingjun.com/run-cloudflare-warp-in-docker/en/#How-it-works) of the upstream project.
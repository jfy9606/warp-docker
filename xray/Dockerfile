# xray multi-IP mode image.
#
# Unlike the main warp-docker image, this image does NOT use the official
# Cloudflare WARP client. It runs xray with N userspace WireGuard tunnels
# (one per SOCKS5 port), so it needs no TUN device, no dbus, no NET_ADMIN
# and no device_cgroup_rules (xray's wireguard outbound uses gVisor with
# noKernelTun). Trade-off: WireGuard protocol only (no MASQUE), no Zero
# Trust. See docs/xray-multi-ip.md.

FROM alpine:3.20

ARG XRAY_VERSION=26.3.27
ARG TARGETARCH

RUN set -eux; \
    arch="${TARGETARCH:-$(uname -m)}"; \
    case "$arch" in \
      x86_64|amd64) xarch=64 ;; \
      aarch64|arm64) xarch=arm64-v8a ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    # musl-utils provides getent, used to resolve the WARP_PROXY hostname
    # outside the tunnel when the proxy URL contains a domain
    apk add --no-cache bash curl jq ca-certificates musl-utils unzip; \
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${xarch}.zip" \
      -o /tmp/xray.zip; \
    unzip -o /tmp/xray.zip -d /usr/local/bin xray; \
    chmod +x /usr/local/bin/xray; \
    rm /tmp/xray.zip; \
    xray version

COPY xray/lib.sh xray/entrypoint.sh xray/rotate.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/lib.sh /usr/local/bin/entrypoint.sh /usr/local/bin/rotate.sh \
    && mkdir -p /etc/xray /var/lib/xray-warp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

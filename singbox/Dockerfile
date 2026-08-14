# sing-box multi-IP mode image.
#
# Unlike the main warp-docker image, this image does NOT use the official
# Cloudflare WARP client. It runs sing-box with N userspace WireGuard
# tunnels (one per SOCKS5 port), so it needs no TUN device, no dbus, no
# NET_ADMIN and no device_cgroup_rules. Trade-off: WireGuard protocol only
# (no MASQUE), no Zero Trust. See docs/singbox-multi-ip.md.

FROM alpine:3.20

ARG SING_BOX_VERSION=1.13.18
ARG TARGETARCH

RUN set -eux; \
    arch="${TARGETARCH:-$(uname -m)}"; \
    case "$arch" in \
      x86_64|amd64) sbarch=amd64 ;; \
      aarch64|arm64) sbarch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    # musl-utils provides getent, used to resolve the WARP_PROXY hostname
    # outside the tunnel when the proxy URL contains a domain
    apk add --no-cache bash curl jq ca-certificates musl-utils; \
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${sbarch}-musl.tar.gz" \
      -o /tmp/sing-box.tar.gz; \
    tar -xzf /tmp/sing-box.tar.gz -C /usr/local/bin --strip-components=1 \
      "sing-box-${SING_BOX_VERSION}-linux-${sbarch}-musl/sing-box"; \
    rm /tmp/sing-box.tar.gz; \
    sing-box version

COPY singbox/lib.sh singbox/entrypoint.sh singbox/rotate.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/lib.sh /usr/local/bin/entrypoint.sh /usr/local/bin/rotate.sh \
    && mkdir -p /etc/singbox /var/lib/singbox-warp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

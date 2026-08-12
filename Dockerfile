ARG BASE_IMAGE=debian:trixie-slim

# download and extract the GOST binary in a separate stage
FROM alpine:3.24 AS gost-builder

ARG GOST_VERSION=3.2.6
ARG TARGETPLATFORM

RUN set -eux; \
    \
    case ${TARGETPLATFORM} in \
      "linux/amd64")   ARCH="amd64" ;; \
      "linux/arm64")   ARCH="arm64" ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac; \
    \
    test -n "${GOST_VERSION}"; \
    apk add --no-cache curl tar; \
    mkdir -p /out; \
    curl -fSL -o /tmp/gost.tar.gz \
      "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"; \
    tar -xzf /tmp/gost.tar.gz -C /out gost; \
    chmod +x /out/gost

FROM ${BASE_IMAGE}

ARG WARP_VERSION
ARG GOST_VERSION
ARG COMMIT_SHA

LABEL org.opencontainers.image.authors="cmj2002"
LABEL org.opencontainers.image.url="https://github.com/cmj2002/warp-docker"
LABEL WARP_VERSION=${WARP_VERSION}
LABEL GOST_VERSION=${GOST_VERSION}
LABEL COMMIT_SHA=${COMMIT_SHA}

COPY entrypoint.sh /entrypoint.sh
COPY rotate-ip.sh /rotate-ip.sh
COPY ./healthcheck /healthcheck
COPY --from=gost-builder /out/gost /usr/bin/gost

# install the WARP client and runtime dependencies
RUN set -eux; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl dbus gnupg sudo jq ipcalc; \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor \
      --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/cloudflare-client.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends cloudflare-warp; \
    \
    # warp-svc does not use the GUI packages below (they are only needed by
    # the graphical WARP client). Drop them from the header of the installed
    # package first so that apt agrees to purge them, saving ~400MB.
    sed -i 's/, libwebkit2gtk-4.1-0//; s/, libayatana-appindicator3-1//; s/, desktop-file-utils//' /var/lib/dpkg/status; \
    apt-get purge -y --allow-change-held-packages \
      libwebkit2gtk-4.1-0 \
      libayatana-appindicator3-1 \
      desktop-file-utils \
      libgtk-3-0 \
      libgtk-3-common; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    chmod +x /entrypoint.sh /rotate-ip.sh /healthcheck/index.sh; \
    useradd -m -s /bin/bash warp; \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

# Accept Cloudflare WARP TOS
RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

ENV GOST_ARGS="-L :1080"
ENV WARP_SLEEP=2
ENV REGISTER_WHEN_MDM_EXISTS=
ENV WARP_LICENSE_KEY=
ENV BETA_FIX_HOST_CONNECTIVITY=
ENV WARP_ENABLE_NAT=
ENV WARP_IP_ROTATE_INTERVAL=

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]
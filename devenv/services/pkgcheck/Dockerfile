ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

ARG PKG_DEPENDS
# kmod-wireguard's install scripts would try to load the module into the host kernel.
RUN mkdir -p /var/lock /var/run && \
    apk update && \
    apk add --no-scripts kmod-wireguard && \
    apk add $PKG_DEPENDS

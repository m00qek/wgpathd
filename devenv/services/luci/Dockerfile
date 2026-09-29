ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

ARG PKG_DEPENDS
ARG APP_DEPENDS
# The rootfs ships LuCI with the bootstrap theme; the two other themes are for the
# theme checks. kmod-wireguard's install scripts would try to load the module into
# the host kernel.
RUN mkdir -p /var/lock /var/run && \
    apk update && \
    apk add --no-scripts kmod-wireguard && \
    apk add $PKG_DEPENDS $APP_DEPENDS uhttpd uhttpd-mod-ubus luci-mod-status \
        luci-theme-bootstrap luci-theme-openwrt-2020 luci-theme-material

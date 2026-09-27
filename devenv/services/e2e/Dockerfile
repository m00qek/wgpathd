ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

ARG PKG_DEPENDS
# wgpathd itself is installed offline from bin/ when a node starts.
# kmod-wireguard's install scripts would try to load the module into the host kernel.
# iputils ping (sub-second intervals) serves the harness only; wgpathd keeps
# probing with busybox ping, as on a router.
RUN mkdir -p /var/lock /var/run && \
    apk update && \
    apk add --no-scripts kmod-wireguard && \
    apk add $PKG_DEPENDS conntrack iputils-ping && \
    mv /usr/bin/ping /usr/libexec/iputils-ping && \
    for s in dnsmasq odhcpd uhttpd dropbear sysntpd urngd cron led gpio_switch packet_steering; do \
      rm -f /etc/rc.d/[SK][0-9][0-9]$s; \
    done

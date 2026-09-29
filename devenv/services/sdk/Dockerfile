# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/sdk:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# /builder is a VOLUME in the base image, so changes to it would not persist.
USER root
RUN cp -a /builder /sdk && chown -R buildbot:buildbot /sdk
USER buildbot
WORKDIR /sdk

# feeds.conf.default pins each feed to the release commit. Only the metadata of
# the packages' runtime DEPENDS is needed; nothing from the feeds is compiled.
RUN ./scripts/feeds update base packages luci && \
    ./scripts/feeds install ucode uclient rpcd-mod-wireguard wireguard-tools luci-base

RUN mkdir -p package/wgpathd

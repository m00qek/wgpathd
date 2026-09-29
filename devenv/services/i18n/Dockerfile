# syntax=docker/dockerfile:1
# The translation template scanner of openwrt/luci (build/i18n-scan.pl), at the commit
# the OpenWrt 25.12.5 SDK pins its luci feed to, with the gettext tools it runs.
FROM alpine:3.23

ARG LUCI_COMMIT=128a7812f4be233c5dd7f7466f534fd888785caf

RUN apk add --no-cache perl gettext
ADD --chmod=755 --checksum=sha256:a1823d1fdd942f31a105e1e53b401e146bc10527f231e016930b1a5123ef21d3 \
    https://raw.githubusercontent.com/openwrt/luci/${LUCI_COMMIT}/build/i18n-scan.pl /usr/local/bin/i18n-scan.pl

# OpenWrt package Makefile for wgpathd (SKELETON — model on ../luci-sso/openwrt).
include $(TOPDIR)/rules.mk

PKG_NAME:=wgpathd
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=TODO
PKG_MAINTAINER:=TODO

include $(INCLUDE_DIR)/package.mk

define Package/wgpathd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WireGuard path selection (hub/spoke direct-vs-relay failover)
  URL:=https://example.invalid/wgpathd
  DEPENDS:=+ucode +ucode-mod-uloop +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +ucode-mod-socket +wireguard-tools +kmod-wireguard
endef

define Package/wgpathd/description
  A ucode daemon that keeps each WireGuard mesh peer pointed at its best working
  path: direct IPv6 when reachable, hub relay otherwise. Endpoints only.
endef

# Preserve operator edits to the config on sysupgrade.
define Package/wgpathd/conffiles
/etc/config/wgpathd
endef

# TODO: Package/wgpathd/install
#   - src/wgpathd/*      -> /usr/lib/ucode/wgpathd/
#   - files/*            -> /   (config, init.d, uci-defaults, sbin, nftables.d)
$(eval $(call BuildPackage,wgpathd))

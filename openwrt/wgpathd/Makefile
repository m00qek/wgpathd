include $(TOPDIR)/rules.mk

PKG_NAME:=wgpathd
PKG_VERSION:=0.1.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=António Mora <m00qek@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/wgpathd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WireGuard path selection (hub/spoke direct-vs-relay failover)
  URL:=https://example.invalid/wgpathd
  DEPENDS:=+ucode +ucode-mod-uloop +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +ucode-mod-log +ucode-mod-socket +ucode-mod-rtnl +ucode-mod-uclient +rpcd-mod-wireguard +wireguard-tools +kmod-wireguard
  PKGARCH:=all
endef

define Package/wgpathd/description
  A ucode daemon that keeps each WireGuard mesh peer pointed at its best working
  path: direct IPv6 when reachable, hub relay otherwise. Endpoints only.
endef

# Preserve operator edits to the config on sysupgrade.
define Package/wgpathd/conffiles
/etc/config/wgpathd
endef

define Build/Compile
endef

# fw4 picks up the nftables.d include on reload: on install, and once it is gone.
define Package/wgpathd/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/firewall reload || true
# An upgrade replaces the code, but default_postinst leaves a running daemon on the old one.
if [ -z "$$IPKG_INSTROOT" ] && [ "$$PKG_UPGRADE" = 1 ] && /etc/init.d/wgpathd running; then
	/etc/init.d/wgpathd restart
fi
endef

define Package/wgpathd/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/firewall reload || true
endef

define Package/wgpathd/install
	$(INSTALL_DIR) $(1)/usr/share/ucode
	$(CP) ./src/wgpathd $(1)/usr/share/ucode/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/wgpathd $(1)/etc/config/wgpathd
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/wgpathd $(1)/etc/init.d/wgpathd
	$(INSTALL_DIR) $(1)/usr/libexec/wgpathd
	$(INSTALL_BIN) ./files/usr/libexec/wgpathd/*.uc $(1)/usr/libexec/wgpathd/
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/chain-pre/input
	$(INSTALL_DATA) ./files/usr/share/nftables.d/chain-pre/input/wgpathd.nft $(1)/usr/share/nftables.d/chain-pre/input/wgpathd.nft
endef

$(eval $(call BuildPackage,wgpathd))

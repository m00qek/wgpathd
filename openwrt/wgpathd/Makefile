include $(TOPDIR)/rules.mk

PKG_NAME:=wgpathd
PKG_VERSION:=0.1.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=António Mora <m00qek@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/wgpathd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WireGuard path selection (hub/spoke direct-vs-relay failover)
  URL:=https://m00qek.github.io/wgpathd/0.1/
  DEPENDS:=+ucode +ucode-mod-uloop +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +ucode-mod-log +ucode-mod-socket +ucode-mod-rtnl +ucode-mod-uclient +rpcd-mod-wireguard +rpcd-mod-ucode +wireguard-tools +kmod-wireguard
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

# rpcd picks up the wgpathd.config plugin on reload: on install, and once it is gone.
# rpcd re-executes itself and keeps its sessions.
define Package/wgpathd/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/rpcd reload || true
# Releases up to 5 shipped an fw4 include. The upgrade has removed it, but its rules
# stay loaded until the firewall reloads.
if [ -z "$$IPKG_INSTROOT" ] && nft list chain inet fw4 input 2>/dev/null | grep -q 'comment "wgpathd: '; then
	/etc/init.d/firewall reload || true
fi
# An upgrade replaces the code, but default_postinst leaves a running daemon on the old one.
# default_postinst has run the package's uci-defaults, so the new one reads migrated settings.
if [ -z "$$IPKG_INSTROOT" ] && [ "$$PKG_UPGRADE" = 1 ] && /etc/init.d/wgpathd running; then
	/etc/init.d/wgpathd restart
fi
endef

define Package/wgpathd/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/rpcd reload || true
endef

define Package/wgpathd/install
	$(INSTALL_DIR) $(1)/usr/share/ucode
	$(CP) ./src/wgpathd $(1)/usr/share/ucode/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/wgpathd $(1)/etc/config/wgpathd
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/wgpathd $(1)/etc/init.d/wgpathd
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/50-wgpathd-peers $(1)/etc/uci-defaults/50-wgpathd-peers
	$(INSTALL_DIR) $(1)/usr/libexec/wgpathd
	$(INSTALL_BIN) ./files/usr/libexec/wgpathd/*.uc $(1)/usr/libexec/wgpathd/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/wgpathd.uc $(1)/usr/share/rpcd/ucode/wgpathd.uc
endef

$(eval $(call BuildPackage,wgpathd))

define Package/luci-app-wgpathd
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for wgpathd
  URL:=https://m00qek.github.io/wgpathd/0.1/
  DEPENDS:=+luci-base +wgpathd
  EXTRA_DEPENDS:=wgpathd (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Package/luci-app-wgpathd/description
  LuCI pages for wgpathd: the live path of each mesh peer, and its settings.
endef

# luci.mk's default postinst, also run on removal: drop LuCI's menu and module caches, reload rpcd for the ACL.
define Package/luci-app-wgpathd/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
endef

Package/luci-app-wgpathd/postrm = $(Package/luci-app-wgpathd/postinst)

define Package/luci-app-wgpathd/install
	$(INSTALL_DIR) $(1)/www
	$(CP) ./luci/htdocs/* $(1)/www/
	$(CP) ./luci/root/* $(1)/
endef

$(eval $(call BuildPackage,luci-app-wgpathd))

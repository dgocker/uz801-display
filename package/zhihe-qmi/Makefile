include $(TOPDIR)/rules.mk

PKG_NAME:=zhihe-qmi
PKG_VERSION:=1.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/zhihe-qmi
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=QMI protocol for Zhihe/Yiming MSM8916 sticks
  DEPENDS:=+qmi-utils +libqmi
  PKGARCH:=all
endef

define Package/zhihe-qmi/description
  netifd protocol handler that brings up the LTE data session with qmicli.
  ModemManager wedges these modems into a permanent offline state, so it is
  deliberately not used.
endef

define Build/Compile
endef

define Package/zhihe-qmi/install
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/lib/netifd/proto/zhiheqmi.sh $(1)/lib/netifd/proto/zhiheqmi.sh

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/98-modem-interface $(1)/etc/uci-defaults/98-modem-interface
endef

define Package/luci-proto-zhiheqmi
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for zhihe-qmi
  DEPENDS:=+zhihe-qmi +luci-base
  PKGARCH:=all
endef

define Package/luci-proto-zhiheqmi/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./files/www/luci-static/resources/protocol/zhiheqmi.js \
		$(1)/www/luci-static/resources/protocol/zhiheqmi.js
endef

$(eval $(call BuildPackage,zhihe-qmi))
$(eval $(call BuildPackage,luci-proto-zhiheqmi))

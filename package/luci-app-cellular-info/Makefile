include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cellular-info
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-cellular-info
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Cellular signal and cell information
  DEPENDS:=+luci-base +qmi-utils +rpcd
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-cellular-info/install
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/cellular_info $(1)/usr/libexec/rpcd/cellular_info

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-cellular-info.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-cellular-info.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-cellular-info.json \
		$(1)/usr/share/luci/menu.d/luci-app-cellular-info.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/cellular_info
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/cellular_info/index.js \
		$(1)/www/luci-static/resources/view/cellular_info/index.js
endef

$(eval $(call BuildPackage,luci-app-cellular-info))

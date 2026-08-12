include $(TOPDIR)/rules.mk

PKG_NAME:=modem-control
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/modem-control
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Modem status and control (single QMI owner)
  DEPENDS:=+luci-base +qmi-utils +rpcd +zhihe-qmi
  PKGARCH:=all
endef

define Package/modem-control/description
  One ubus service owns the QMI channel; the LCD dashboard, the info page and
  the control page all read through it, so nothing ever talks to the modem
  concurrently. Long operations run detached and roll back if the modem fails
  to register.
endef

define Build/Compile
endef

define Package/modem-control/install
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/modem $(1)/usr/libexec/rpcd/modem

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/modem-control.json \
		$(1)/usr/share/rpcd/acl.d/modem-control.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/modem-control.json \
		$(1)/usr/share/luci/menu.d/modem-control.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/modem_control
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/modem_control/index.js \
		$(1)/www/luci-static/resources/view/modem_control/index.js
endef

$(eval $(call BuildPackage,modem-control))

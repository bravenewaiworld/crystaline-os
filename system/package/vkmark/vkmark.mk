################################################################################
#
# vkmark
#
################################################################################

VKMARK_VERSION = 83a128d65b1adddfacb4fa2e555a7e90817a7266
VKMARK_SITE = $(call github,vkmark,vkmark,$(VKMARK_VERSION))
VKMARK_LICENSE = LGPL-2.1+
VKMARK_LICENSE_FILES = COPYING-LGPL2.1
VKMARK_DEPENDENCIES = host-pkgconf assimp glm libdrm vulkan-headers vulkan-loader
# The display and headless window systems are always built; kms needs GBM (Mesa's).
VKMARK_CONF_OPTS = -Dxcb=false -Dwayland=false
ifeq ($(BR2_PACKAGE_HAS_LIBGBM),y)
VKMARK_DEPENDENCIES += libgbm
VKMARK_CONF_OPTS += -Dkms=true
else
VKMARK_CONF_OPTS += -Dkms=false
endif

$(eval $(meson-package))

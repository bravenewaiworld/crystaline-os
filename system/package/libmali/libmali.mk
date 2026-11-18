################################################################################
#
# libmali
#
################################################################################

# Rockchip's builds, from the mirror (and commit) ROCKNIX uses for the RK3566. Only the one library
# is downloaded.
LIBMALI_VERSION = 4233031d818e97a19e8a9cdbbd5c15795ededd93
LIBMALI_LIB = libmali-bifrost-g52-g29p1.so
LIBMALI_SITE = https://github.com/JeffyCN/mirrors/raw/$(LIBMALI_VERSION)/lib/aarch64-linux-gnu
LIBMALI_SOURCE = $(LIBMALI_LIB)
LIBMALI_LICENSE = ARM Mali EULA (closed)
LIBMALI_REDISTRIBUTE = NO
LIBMALI_DEPENDENCIES = libdrm

define LIBMALI_EXTRACT_CMDS
	cp $(LIBMALI_DL_DIR)/$(LIBMALI_SOURCE) $(@D)/
endef

# The library under /usr/lib/mali with the names programs load (libEGL.so.1, ...), and a Vulkan
# driver manifest in /usr/share/crystaline/mali/vulkan/icd.d; the start-up hooks put them in place
# of Mesa's while ARM's driver is in use.
define LIBMALI_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/$(LIBMALI_LIB) $(TARGET_DIR)/usr/lib/mali/$(LIBMALI_LIB)
	for l in libmali.so.1 libEGL.so.1 libGLESv1_CM.so.1 libGLESv2.so.2 libgbm.so.1; do \
		ln -sf $(LIBMALI_LIB) $(TARGET_DIR)/usr/lib/mali/$$l || exit 1; \
	done
	mkdir -p $(TARGET_DIR)/usr/share/crystaline/mali/vulkan/icd.d
	printf '{ "file_format_version": "1.0.0",\n  "ICD": { "library_path": "/usr/lib/mali/%s", "api_version": "1.3.0" } }\n' \
		$(LIBMALI_LIB) >$(TARGET_DIR)/usr/share/crystaline/mali/vulkan/icd.d/mali_icd.json
endef

$(eval $(generic-package))

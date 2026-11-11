################################################################################
#
# vulkan-wsi-layer
#
################################################################################

# The commit ROCKNIX ships for libmali on its RK3566 builds.
VULKAN_WSI_LAYER_VERSION = 40cfec09d0e2d42c5e1f2642cf4cba11e7008112
VULKAN_WSI_LAYER_SITE = $(call github,ginkage,vulkan-wsi-layer,$(VULKAN_WSI_LAYER_VERSION))
VULKAN_WSI_LAYER_LICENSE = MIT
VULKAN_WSI_LAYER_LICENSE_FILES = LICENSE
VULKAN_WSI_LAYER_DEPENDENCIES = host-pkgconf libdrm vulkan-headers vulkan-loader
# The layer is written against newer Vulkan headers (1.4.356) than Buildroot's; it is built with
# these, which are only headers (the loader's interface to layers doesn't change between them).
VULKAN_WSI_LAYER_HEADERS = vulkan-sdk-1.4.357.0
VULKAN_WSI_LAYER_EXTRA_DOWNLOADS = \
	https://github.com/KhronosGroup/Vulkan-Headers/archive/$(VULKAN_WSI_LAYER_HEADERS).tar.gz
define VULKAN_WSI_LAYER_EXTRACT_HEADERS
	mkdir -p $(@D)/vulkan-headers
	$(call suitable-extractor,$(VULKAN_WSI_LAYER_HEADERS).tar.gz) \
		$(VULKAN_WSI_LAYER_DL_DIR)/$(VULKAN_WSI_LAYER_HEADERS).tar.gz | \
		$(TAR) --strip-components=1 -C $(@D)/vulkan-headers $(TAR_OPTIONS) -
endef
VULKAN_WSI_LAYER_POST_EXTRACT_HOOKS += VULKAN_WSI_LAYER_EXTRACT_HEADERS
# The panel through KMS and headless surfaces; no Wayland or X11. Buffers come from the kernel's
# "system" dma-buf heap.
VULKAN_WSI_LAYER_CONF_OPTS = \
	-DBUILD_WSI_DISPLAY=ON \
	-DBUILD_WSI_HEADLESS=ON \
	-DBUILD_WSI_WAYLAND=OFF \
	-DBUILD_WSI_X11=OFF \
	-DSELECT_EXTERNAL_ALLOCATOR=dma_buf_heaps \
	-DWSIALLOC_MEMORY_HEAP_NAME=system \
	-DVULKAN_CXX_INCLUDE=$(@D)/vulkan-headers/include \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DCMAKE_CXX_FLAGS="$(TARGET_CXXFLAGS) -UNDEBUG"
# -UNDEBUG keeps the layer's log (stderr; VULKAN_WSI_DEBUG_LEVEL=1 errors .. 3 info), which release
# builds compile out, and its assertions: this driver is still being brought up on our boards.

# The layer's manifest goes to /usr/share/crystaline/mali/vulkan/, not the loader's folder: the
# start-up hooks put that folder in place of /usr/share/vulkan only while ARM's driver is in use (the
# layer would wrap Mesa's drivers too).
define VULKAN_WSI_LAYER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libVkLayer_window_system_integration.so \
		$(TARGET_DIR)/usr/lib/libVkLayer_window_system_integration.so
	$(INSTALL) -D -m 0644 $(@D)/layer/VkLayer_window_system_integration.json \
		$(TARGET_DIR)/usr/share/crystaline/mali/vulkan/implicit_layer.d/VkLayer_window_system_integration.json
endef

$(eval $(cmake-package))

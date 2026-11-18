include $(sort $(wildcard $(BR2_EXTERNAL_CRYSTALINE_PATH)/package/*/*.mk))

# vulkan-tools: also vkcube, drawing straight to the panel through VK_KHR_display (no window
# system), to check a Vulkan driver's presentation on the device. Buildroot builds only vulkaninfo.
# (Appended to the package's options, which cmake reads last-wins.)
ifeq ($(BR2_PACKAGE_VULKAN_TOOLS),y)
VULKAN_TOOLS_CONF_OPTS += -DBUILD_CUBE=ON -DCUBE_WSI_SELECTION=DISPLAY
endif

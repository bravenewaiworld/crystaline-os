# The RGB20 Pro's third-party inputs (sourced by tools/fetch-third-party.sh): the RTL8723DS's
# Bluetooth firmware and UART settings, from Armbian's firmware collection (rtl_bt/), for parts.sh.
RTL_BT=https://raw.githubusercontent.com/armbian/firmware/bf5f7a802b8e1998e6bf95daed5ea965441af83d/rtl_bt
download rtl8723ds-bt/rtl8723ds_fw.bin $RTL_BT/rtl8723ds_fw.bin \
	19c1bed7a9359b1a021c20f81b525bdebf5067f9021716991d94be9101f76e63
download rtl8723ds-bt/rtl8723ds_config.bin $RTL_BT/rtl8723ds_config.bin \
	7d1e18df7654da8f6382520841bb535f2d1246fc8495e3ae652f7b23e820168d

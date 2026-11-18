# The RGB20 Pro's files for the root filesystem (sourced by tools/system/build-system.sh): the
# RTL8723DS's Bluetooth firmware and its UART settings, which linux-firmware doesn't carry
# (fetch.sh).
for f in rtl8723ds_fw.bin rtl8723ds_config.bin; do put "$ROOT/third-party/rtl8723ds-bt/$f" /lib/firmware/rtl_bt/$f 644; done

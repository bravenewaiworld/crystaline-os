# Mainline family and the RGB20 Pro

Status: In progress · Updated: 2026-11-11

The boards that run mainline Linux, starting with the Powkiddy RGB20 Pro (Rockchip RK3566, 4x Cortex-A55, Mali-G52, 1 GB RAM, 1024x768 DSI panel, two SD slots and no internal storage). How their kernel, card and graphics work; the layering they share with the Brick is in [boards.md](boards.md).

## Decisions

- **Kernel: our fork of Linux 7.3 stable, crystaline-linux-mainline (submodule `linux-mainline`, branch `crystaline-7.3`), built with Buildroot's GCC 14** (2026-11-11). Our commits are prefixed by layer (`rockchip:`, `powkiddy:`, `rgb20pro:`); the only out-of-tree driver carried is ROCKNIX's generic DSI panel driver. Its configuration is merged from `system/family/mainline/kernel.config`, each SoC's and each board's part (`tools/mainline/kmake.sh`). Rejected: a branch of the Brick's 4.9 tree (shares nothing).
- **ROCKNIX's prebuilt loader and U-Boot until we build our own** (2026-11-11): the first 16 MiB of a ROCKNIX card (third-party input `RK3566_UBOOT`). It reads GPT and extlinux.conf.
- **The card is laid out like the Brick's: GPT, FAT `bootloader`, ext4 `system`, FAT games partition made on first start** (2026-11-11), so the initramfs, mount-card and the installer work unchanged. The boot partition holds `extlinux/extlinux.conf` and a boot slot folder per version (`a/`, later `b/`). Rejected: one FAT partition for boot files and games (mixes them in the folder people drop games into).
- **Panfrost (Mesa) is the GPU driver; ARM's libmali is an option** (2026-11-11). Panfrost is open, 45 % faster in glmark2 under ROCKNIX and in vkmark here, and works with KMS directly. libmali is a complete, conformant Vulkan 1.3 driver where PanVK is a partial Vulkan 1.0 one, so it stays available for trying games that need it: `crystaline-gpu panfrost|mali` (from the next start).
- **Mesa is built without LLVM on the device** (2026-11-11): its shaders are compiled on the build machine (`system/buildroot-patches/0001-*`), which also adds the PanVK option Buildroot lacks.
- **The panel stays at 60 Hz** (2026-11-11) until its modes give the rates they claim (Findings).

## Design

```text
card (GPT)                         boot (U-Boot → extlinux.conf DEFAULT a)
  0-33       GPT                     a/Image, a/initramfs.cpio.gz, a/dtbs/<board DTB>
  64-32767   loader + U-Boot         APPEND root=UUID=<system> crystaline.boot=a console=ttyS2,1500000
  16 MiB     bootloader (FAT, 256M)         console=tty0 log_buf_len=1M loglevel=4 panic=10
  then       system (ext4, 1 GiB): images/<version>/, state/, logs/, overlay/<version>/
  rest       games (FAT, made on first start)
```

ARM's driver, when chosen: `start_hardware` loads `mali_kbase.ko` (kept out of the module index) and bind-mounts `/usr/lib/mali/*` over Mesa's libraries and `/usr/share/crystaline/mali/vulkan` over `/usr/share/vulkan` (libmali's ICD plus ARM's window-system layer, built for VK_KHR_display and headless surfaces). Our patch to the layer has it take the DRM device before libmali's `vkCreateInstance`, which otherwise becomes DRM master without using it.

## Findings

- (2026-11-11, device) Every panel mode runs at about 59.3 Hz except 120 Hz: the display clock (dclk_vop1 from pll_vpll) stays at 101 MHz, so modes get 50.5 MHz (the 60 Hz mode wants 51.07, 90 Hz 77.04) or 101 MHz (120 Hz wants 102.72). 90 and 120 Hz show a blank screen with the backlight on; 60 Hz is fine. Source: rgb20pro/inventory/panel-mode-clocks-ours.txt (outside the repository).
- (2026-11-11, device) vkmark 1024x768 off-screen: PanVK 594, libmali g29p1 409; on the panel through KMS, PanVK 529. libmali reports Vulkan 1.3.303, conformance 1.4.1.0; PanVK Vulkan 1.0, non-conformant, only with `PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1`.
- (2026-11-11, device) PanVK's own VK_KHR_display finds no display (vkmark `--winsys display`); its KMS path (`--winsys kms`) works.
- (2026-11-11, device) mdev's start-up scan loads no driver for devices without a `/dev` node, the GPU among them: `start_hardware` loads it.
- (2026-11-11, device) "mmc1: error -5 whilst initialising SD card" at every start is the first SDR104 tuning failing; the kernel retries and succeeds (ROCKNIX shows the same).
- (2026-11-11, device) mali_kbase logs "IRQ JOB/MMU/GPU not found" (it tries upper-case interrupt names first; the lower-case ones work) and a regulator-disable warning at runtime suspend.
- (2026-11-11, device) The USB-C ports have no CC resistors: a USB-C-to-C cable gives no power or data. The DC port with a USB-A host end is the data port.

## Open questions

- Which PLL settings give each panel mode its exact clock, and do 90 and 120 Hz then show? (A kernel patch adding the modes' rates to the RK3568 PLL table, then the same vkmark runs.)
- Why does PanVK's VK_KHR_display find no display on the Rockchip display/GPU split?

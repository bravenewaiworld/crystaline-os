# Mainline family and the RGB20 Pro

Status: In progress · Updated: 2026-11-12

The boards that run mainline Linux, starting with the Powkiddy RGB20 Pro (Rockchip RK3566, 4x Cortex-A55, Mali-G52, 1 GB RAM, 1024x768 DSI panel, two SD slots and no internal storage). How their kernel, card and graphics work; the layering they share with the Brick is in [boards.md](boards.md).

## Decisions

- **Kernel: our fork of Linux 7.3 stable, crystaline-linux-mainline (submodule `linux-mainline`, branch `crystaline-7.3`), built with Buildroot's GCC 14** (2026-11-11). Our commits are prefixed by layer (`rockchip:`, `powkiddy:`, `rgb20pro:`); the only out-of-tree driver carried is ROCKNIX's generic DSI panel driver. Its configuration is merged from `system/family/mainline/kernel.config`, each SoC's and each board's part (`tools/mainline/kmake.sh`). Rejected: a branch of the Brick's 4.9 tree (shares nothing).
- **The loader is built from source; only Rockchip's DDR init stays a binary** (2026-11-12): U-Boot v2026.10 with our RGB20 Pro configuration (`system/board/rgb20pro/u-boot/`) on the RK2023's device tree, which is the same board, so U-Boot sets up the real power rails; open TF-A as BL31, at a commit after v2.15 for its GPU-after-sleep fix; Rockchip's `rk3566_ddr_1056MHz_v1.23.bin`, byte for byte the DDR init ROCKNIX's cards carry (`make DEVICE=rgb20pro loader`, `tools/mainline/build-loader.sh`). U-Boot reads GPT and extlinux.conf, starts only from the first slot, and powers off again when started by plugging in a charger. Rejected: ROCKNIX's prebuilt loader (used until stage 5; it runs as the RG353 with Rockchip's closed BL31), Rockchip's closed BL31 (kept as `RK3566_BL31` for comparison).
- **The card is laid out like the Brick's: GPT, U-Boot's settings in `env` and `env-redund`, boot slots `boot_a` and `boot_b`, ext4 `system`, FAT games partition made on first start** (2026-11-11; boot slots 2026-11-12), so the initramfs, mount-card and the installer work unchanged. A version's `boot.img` is a FAT image (`extlinux.conf`, kernel, initramfs, the family's device trees) written raw into a slot; U-Boot's settings name the slot (`boot_partition`) and the system partition (`mmc_root`), which `extlinux.conf` passes on, so one `boot.img` fits either slot of any card, and updates switch slots exactly as on the Brick. Rejected: one FAT partition for boot files and games (mixes them in the folder people drop games into); one FAT boot partition with a folder per slot and `extlinux.conf`'s `DEFAULT` changed in place (writing a slot's files touches the allocation table the slot choice is read through, and needs a second slot method in the installer).
- **The status screen, the start-up's messages and the recovery menu draw on `/dev/fb0`, here DRM's emulation of a framebuffer (on the Brick, its display driver's own)** (2026-11-12), so `status` is one program for both families: the emulation keeps room for two screens (`CONFIG_DRM_FBDEV_OVERALLOC=200`), since `status` draws each frame on the hidden one and then shows it, and `status` switches the kernel's text console, which mainline boards show on the screen, to graphics mode so it draws nothing over it. It shows only while nothing else holds the display (Specular does, while it runs). The recovery menu opens with SELECT and START held at power-on ([boot.md](boot.md)). Rejected: drawing through KMS in `status` (a second drawing path, for the same pixels).
- **Panfrost (Mesa) is the GPU driver; ARM's libmali is an option** (2026-11-11). Panfrost is open, 45 % faster in glmark2 under ROCKNIX and in vkmark here, and works with KMS directly. libmali is a complete, conformant Vulkan 1.3 driver where PanVK is a partial Vulkan 1.0 one, so it stays available for trying games that need it: `crystaline-gpu panfrost|mali` (from the next start).
- **Mesa is built without LLVM on the device** (2026-11-11): its shaders are compiled on the build machine (`system/buildroot-patches/0001-*`), which also adds the PanVK option Buildroot lacks.
- **The panel stays at 60 Hz** (2026-11-11) until its modes give the rates they claim (Findings).

## Design

```text
card (GPT)                         boot (U-Boot starts the slot boot_partition names)
  0-33       GPT                     boot.img (FAT): extlinux/extlinux.conf, Image, initramfs.cpio.gz,
  64-32767   loader (build-loader.sh)               dtbs/ (fdtfile, in U-Boot's settings, picks one)
  16 MiB     env, env-redund (128 KiB each)  APPEND root=${mmc_root} crystaline.boot=${boot_partition}
  17 MiB     boot_a (64 MiB)                        console=ttyS2,1500000 console=tty0 log_buf_len=1M
  81 MiB     boot_b (64 MiB)                        loglevel=4 panic=10
  145 MiB    system (ext4, 1 GiB): images/<version>/, state/, logs/, overlay/<version>/
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

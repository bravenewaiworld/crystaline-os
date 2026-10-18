# GPU

Status: Implemented · Updated: 2026-10-18

The TrimUI Brick's PowerVR GE8300 GPU (Imagination "Rogue", core ID or BVNC 22.102.54.38) and how we drive it: Imagination's closed driver kit (DDK) 1.19, with the kernel half rebuilt from source and the user libraries taken from TrimUI's firmware. It gives OpenGL ES 3.2 and EGL 1.4 drawing straight to the screen, with no X11 or Wayland, which shapes how Specular and the emulators present frames. The screen side of presenting is in [display.md](display.md).

## Decisions

- **TrimUI's closed DDK 1.19 user libraries, with the kernel module built from source** (2026-10-10). PocketForge's `gpu-km-tsp` is the kernel half of DDK 1.19@6345021, the version TrimUI ships, retargeted to the A133 with a port of the `dc_sunxi` display module and build settings that pass the stock libraries' version check. It loads TrimUI's firmware and runs TrimUI's libraries unchanged, and being source we can fix it (see the lock-order patch). Rejected: TrimUI's binary `pvrsrvkm.ko` (built for TrimUI's kernel, can't be fixed); the Creality Sonic Pad's DDK 1.11 (source and libraries public, but older and also screen-only); the mainline `drm/imagination` driver with Mesa (GE8300 marked unsupported, needs a mainline kernel, no display path; see Findings).
- **Only the "NULL" window system: EGL draws to the whole screen** (2026-10-10). No public arm64 PowerVR user mode for this core has a Wayland or X11 window system, and Imagination's own need a KMS display driver the A133 BSP lacks. A compositor would need a custom window-system plugin and one extra full-screen copy per frame (about 190 MB/s and 2 ms of one core at 60 fps). Specular is the only GPU client, so it needs none. Rejected: Weston (its fbdev backend was removed in Weston 11, and was CPU-only before); wlroots (needs DRM); Xorg's fbdev driver (would still need the custom plugin and the copy).
- **Our fixes to the driver are patches applied at build time** (2026-10-12). `tools/build-gpu.sh` mirrors the source into the build directory, applies `tools/gpu-patches/*.patch`, and builds there, so the upstream checkout stays clean and each patch documents one fix.
- **Only the EGL and OpenGL ES libraries are shipped.** TrimUI's Vulkan (`libVK_IMG.so` plus the 36 MB `libufwriter.so`), OpenCL, OpenGL ES 1.1 and PVRScope libraries are left out until something needs them.

## Design

```
Specular (EGL, eglCreateWindowSurface with a NULL window = the whole screen)
  → libEGL / libIMGegl / libGLESv2 / libsrv_um / libpvrNULL_WSEGL   (TrimUI's, DDK 1.19)
  → /dev/dri/card0 → pvrsrvkm.ko (GPU services; loads /lib/firmware/rgx.{fw,sh}.22.102.54.38)
  → dc_sunxi.ko: each present pans /dev/fb0 to the finished buffer
    (64 MiB fb0 = 1024×16384 virtual); disp2's pan waits for the next vsync
```

- **Build.** `tools/build-gpu.sh` builds `pvrsrvkm.ko` and `dc_sunxi.ko` against our kernel tree with `PVR_SYSTEM=sunxi_a133`. That platform's config pins the build-options word and version that TrimUI's libraries compare with the module's when they connect; if they differ, the libraries refuse to run. User mode, kernel module and firmware must all be the same DDK version.
- **Image.** The system image copies the user libraries and `rgx.*` firmware from TrimUI's root filesystem (`tools/system/build-system.sh`); `rcS` loads `pvrsrvkm` then `dc_sunxi` at boot.
- **Locking.** `dc_sunxi` takes the console lock, then the framebuffer (`fb_info`) lock, the same order as the kernel's fbdev code (`tools/gpu-patches/0001-dc_sunxi-lock-order.patch`). Because every flip takes the console lock, anything printing to the serial console delays flips; the console log level is 4 (warnings and worse).
- **Clock and power.** As stock: GPU clock fixed at 702 MHz, no frequency scaling or voltage control; the GPU's power domain powers itself down when idle.

## Findings

- (2026-10-10, stock) Device tree: `gpu@0x01800000`, SPI 97, clocks `clk_pll_gpu` and `clk_gpu`, power domain `gpu-power-domain@07001000` (`allwinner,gpu-pd`, SPI 119, clock `ppu`). Operating points 700 MHz @ 1.1 V, 399 MHz @ 0.95 V, 228 MHz @ 0.95 V, but no `gpu-supply`, so the driver never sets a voltage. TrimUI's spec sheet says 660 MHz.
- (2026-10-10, device) Stock runs the GPU fixed at 702 MHz (pll_gpu N=117 /2/2, module clock undivided) with "dvfs:0 power:0 volt:0"; the 399 and 228 MHz points are rejected at boot (`sunxi_decide_pll`). The power domain powers down when idle (18 times, about 1100 power-controller interrupts in 66 s).
- (2026-10-10, stock) TrimUI ships DDK 1.19@6345021: `pvrsrvkm.ko`, `dc_sunxi.ko`, firmware `rgx.fw.22.102.54.38` (118 784 B) and `rgx.sh.22.102.54.38` (404 192 B), and user libraries for OpenGL ES 3.2 and 1.1, EGL, Vulkan and OpenCL 3.0, with only the NULL window system. Its SDL2 (2.30.8) uses a "mali" fbdev-style EGL video driver.
- (2026-10-10, device) On our kernel the source-built module reads the BVNC from the hardware, loads stock firmware and serves TrimUI's libraries unchanged: client build options 0x80000010 & mask 0xfffb = 0x10, build 6345021, version 1.19 match. `glspin` runs a steady 60.2 fps, locked to vsync; stock's `opengles_demo` draws a static grid (not a hang). Source: tools/device/glspin.c; github.com/pocketforge-os/gpu-km-tsp.
- (2026-10-10, device) The user libraries are effectively per-core: `libsrv_um.so` embeds only "22.102.54.38". Source: TrimUI's `libsrv_um.so`.
- (2026-10-10, device) Building blocks for a custom window system in TrimUI's libraries: `EGL_EXT_image_dma_buf_import` (with modifiers), `EGL_KHR_image_base`, `EGL_KHR_surfaceless_context`, `EGL_KHR_fence_sync`, `GL_OES_EGL_image(_external)`; `libsrv_um` has `PVRSRVDmaBufImport*` / `ExportDevMem*`; EGL loads the window-system plugin named by `WindowSystem` in `/etc/powervr.ini` (plugins export `WSEGL_GetFunctionTablePointer`). No EGL dma-buf export. Earlier custom plugins exist for SGX (nemomobile `ti-omap3-sgx-wayland-wsegl`, TexasInstruments `dri3wsegl`). Source: TrimUI's libraries.
- (2026-10-10, upstream) Other DDKs checked: StarFive's JH7110 kernels carry DDK 1.19@6345021 (including this core's header) on 5.15, 6.6 and 6.12, but their user mode is riscv64 only; TI's arm64 Wayland/GBM releases skip 1.19 and ship firmware only for their own cores; Allwinner's Android A133 DDK is 1.18 (bionic); Renesas' GE8300 packages are a different BVNC behind registration; the Sonic Pad DDK 1.11 (kernel source in `sonic_pad_os`, libraries at knulli-cfw/ge8300-drivers) is fbdev-only.
- (2026-10, upstream) Mainline `drm/imagination` treats GE8300 as unknown (needs `exp_hw_support=1`) and has no device-tree binding for it; its firmware `rogue_22.102.54.38_v1.fw` is only in Imagination's linux-firmware `powervr` branch. Mesa lists GE8300 as "unsupported, not under active development" (Vulkan needs `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`); OpenGL ES comes only through Zink (2.0 since Mesa 26.1, 3.1 hoped for 26.3). PocketForge reports offscreen rendering with mainline `powervr.ko` and Mesa on an A133 in a private tree; on-screen output unproven.
- (2026-10-12, device) `dc_sunxi` took the framebuffer lock before the console lock on every flip (and at load and unload), the reverse of the kernel's fbdev code, so another program making a framebuffer call (e.g. `FBIOPUT_VSCREENINFO`) while a GPU app presented deadlocked the display, and suspend behind it. Fixed by the lock-order patch; checked by starting the status screen three times during a GPU app and sleeping during one, 60 fps throughout. Source: tools/gpu-patches/0001-dc_sunxi-lock-order.patch.
- (2026-10-12, device) Each kernel log line on the 115200-baud serial console holds a CPU and the console lock for about 5 ms, and every flip needs that lock. Source: repo commit 0ea7eb2.
- (2026-10-17, device) Allwinner's default kernel config turned slab debugging on for every allocation; `drm_ioctl` allocates and frees per call, which cost a game's render thread about 12 % of its time. Off by default now (`slub_debug=` re-enables it for one boot). Source: linux ff670b52c.
- (2026-10-10, stock) The GPU thermal zone (sensor 1) has no trip points, so nothing slows the GPU when hot.

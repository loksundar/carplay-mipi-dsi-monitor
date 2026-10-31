# FBrowser on the V831 screen — research (2026-10-30, nothing implemented)

## Verdict
Feasible but tight. The only zero-flash-risk host today is a **compressed squashfs image held in RAM**,
downloaded over WiFi at boot. Expected peak ≈ 75–80 MB of the 91.5 MB available, so plain pages are
fine and anything heavy will OOM. Getting the SD slot working (try another card) would cut ~22 MB from that.

## Brief vs. measured reality
| Brief assumption | Measured on the device |
|---|---|
| "~2.3 MB free flash" | rootfs_min uses 1.9 of 10.6 MB → ~8.7 MB free. Still far too small (browser ≈ 20 MB compressed). |
| "Run from SD card" | SD slot doesn't work: `mmc0: card never left busy state`, no /dev/mmcblk*. Card or slot unknown. |
| "Check free RAM after stock services" | Stock services are gone. MemAvailable 91.5 MB, tmpfs /tmp capped at 61 MB, **no swap**, no zram. |
| "Use the Tina musl toolchain" | Not needed: run in a chroot that brings its own libc (kernel 4.9 is fine for glibc ≥ 2.31). |
| "armv6 prebuilt" | Never published. The only release is `rootfs_riscv64.tar.xz` (48.8 MB). |
| fbdash path confirmed | Yes, working. |

## Hardware/kernel facts that matter
- CPU: 1× Cortex-A7, up to 1.008 GHz, NEON/VFPv4 (faster than the Pi Zero FBrowser was tested on).
- Filesystems in kernel: squashfs (**xz only**), jffs2, vfat, exfat, overlay, tmpfs. No NFS/CIFS/FUSE.
- **squashfs must use the vendor's reordered superblock** (the kernel reads the custom layout) → build
  images with our patched mksquashfs (`carplay-sqfs` Docker image), not stock mksquashfs. Verify a
  test mount early.
- Loop devices: /dev/loop0, /dev/loop1 available.
- Display: fb0 1600×600 BGRA (rgb@16/8/0). The kernel only copies fb0 → panel when FBIOPAN_DISPLAY is
  called **with a dirty rect in var.reserved[0..3]**. Qt's linuxfb plugin never pans, so FBrowser would
  draw into fb0 and **the screen would keep showing the old image**. Needs one of:
  a) patch `qlinuxfbscreen.cpp` to pan with the dirty rect after each flush (clean, per-repaint), or
  b) a helper that pans the full screen at ~4 Hz (each pan = kernel software rotate of 3.84 MB; ~10% CPU).
- Touch: GT911 → /dev/input/event4, X 0..1600 / Y 0..600 matching fb0. Qt: `QT_QPA_GENERIC_PLUGINS=evdevtouch:/dev/input/event4`.

## Size (from the riscv64 release; ARMv7 Thumb-2 should be similar or a bit smaller)
Release rootfs is 179.5 MB uncompressed, mostly removable (Python, GStreamer, wpa_supplicant, modules).
Essential core, measured with xz -6:

| file | raw | xz |
|---|---|---|
| libQt5WebKit 5.212 | 31.5 MB | 7.2 MB |
| libicudata 69 | 27.3 MB | 6.7 MB |
| Qt5 Core+Gui+Widgets+Network | 18.7 MB | 5.6 MB |
| libicui18n + libicuuc | 5.2 MB | 1.5 MB |
| **core total** | **82 MB** | **20 MB** |

Plus libc/libstdc++/freetype/png/jpeg/xml2/sqlite/one font ≈ +3 MB xz → **~22–25 MB image**.

## RAM budget (RAM-hosted squashfs)
- squashfs image in tmpfs (pinned): ~22 MB
- decompressed page cache for touched code/data: ~15–20 MB (reclaimable, but each reclaim is re-decompressed xz)
- FBrowser process (JSC + WebCore + 1600×600 backing stores): ~30–40 MB for a simple page
- **total ≈ 70–80 MB vs 91.5 MB available**, so ~10–20 MB headroom. Keep the page static-ish: no frameworks,
  small images, no CSS animations, and avoid `DeveloperExtras`/`WebAudio`/local storage.
- If the SD slot works with another card, loop-mount the image from SD instead → saves the 22 MB.

## Build options
1. **Debian armhf chroot (recommended prototype, ~1 h)**: Debian bookworm/bullseye ship
   `libqt5webkit5` 5.212 for armhf (8.9 MB .deb). Build FBrowser's 3 source files natively in a
   `--platform linux/arm/v7` Debian container, collect libs via ldd + Qt platform/generic plugins + one
   font, then mksquashfs (patched) the result. No custom toolchain.
2. **Buildroot (final/trimmed, multi-hour build)**: `qt5webkit` is still packaged (checked 2022.02–2024.02).
   Allows ICU data trimming, `-Os`, and a patched linuxfb plugin. Target cortex-a7 hf NEON, kernel headers 4.9.

## Run plan (when we implement)
At boot or on demand: fbdash GET the image into /tmp → `mount -o loop,ro` → bind /dev /proc /sys →
`chroot` → `QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0` + touch env + pan helper → FBrowser loads the Mac's
dashboard URL. Stop fbdash first, since both draw to fb0. Gate with an OOM test first: load the page,
watch MemAvailable for 10 minutes via the command channel. Nothing touches flash. A reboot returns to fbdash.

## Security
FBrowser enables `OSBridge` by default (page JS can run host commands as root) and QtWebKit 5.212 has
unpatched CVEs. Set `"enableOSBridge": false` and only load our own LAN dashboard.

## Alternative worth weighing
Keep the device dumb: render the page with headless Chromium on the Mac (full modern web), send frames via
fbdash, and forward touch coordinates to the Mac, which clicks into the headless page. Zero device RAM risk and
better fidelity. The cost is ~0.5–1.5 s per touch round-trip over WiFi instead of local, instant interaction.

# Hardware and firmware facts (all verified on the device)

## Board
- SoC: Allwinner **V831** (sun8iw19p1), one Cortex-A7 @ 1 GHz (CPU governor set to `performance` at boot).
- RAM: 128 MB physical (0x40000000-0x47ffffff); `MemTotal` 122100 kB, ~86 MB available while running.
  `cma=8M`, display reserve 256 KB.
- Flash: 16 MB SPI NOR.
- Kernel: Linux 4.9.118 (Allwinner "Tina" BSP, built May 2023), PREEMPT, armv7l. BusyBox userland.
- Panel interface: **MIPI DSI**, 4 lanes, RGB888, native 600x1600, ~57 MHz pixel clock (device tree: `lcd_driver_name
  = "default_mipi"`, `lcd_if = 4`, `lcd_dsi_lane = 4`). The panel is wired straight to the SoC: there is no HDMI or
  other video input, which is why the SoC itself acts as the "monitor" and the picture arrives over USB/WiFi. We
  never touch DSI: the vendor kernel driver keeps driving the panel; we only draw into the framebuffer.
- Display: panel 600x1600 portrait. `/dev/fb0` is presented as **1600x600 BGRA** (line 6400 bytes); the kernel
  rotates it onto the panel with G2D ("sw rotation" layer ch2/lyr0). Refresh only happens for the rect passed in
  `fb_var_screeninfo.reserved[0..3]` with `FBIOPAN_DISPLAY`.
- Touch: Goodix **GT911** on i2c-3 @ 0x5d, driver `gt9xxnew_ts` → `/dev/input/event4`; multitouch protocol A,
  X 0..1600 / Y 0..600, same orientation as fb0. The FPC cable must be inserted contacts-to-pins (wrong way = no touch).
- WiFi: AP6334 module (BCM4334), driver `bcmdhd`, STA firmware only. Needs the RTC 32 kHz clock output enabled
  (`echo 0x07000060 1 > /sys/class/sunxi_dump/write`); RTC registers survive warm resets, so the bug only shows on
  cold boots. **Always validate base-image changes with a real power-off.**
- USB-C: OTG via sunxi usbc0, UDC `5100000.udc-controller`. Powered from the Mac's USB port.
- SD slot (sdc0) fails to initialise ("card never left busy state"): unusable, everything goes through the command channel.
- Watchdog: 16 s hardware watchdog armed at boot; must be fed (`watchdog -t 2 /dev/watchdog`), writing
  watchdog0/switch is EPERM.

## Flash layout (from /proc/mtd + GPT, mbr_offset 0x4C000)

| Partition | mtd | Offset | Size | Contents |
|---|---|---|---|---|
| uboot | mtd0 | 0x000000 | 0x050000 | boot0 + U-Boot |
| boot | mtd1 | 0x050000 | 0x270000 | kernel |
| rootfs | mtd2 | 0x2C0000 | 0xAA0000 | squashfs (xz, 256 KB blocks, vendor-modified superblock) |
| res | mtd3 | 0xD60000 | 0x1F0000 | vendor resources |
| overlay | mtd4 | 0xF50000 | 0x080000 | jffs2, overlayfs upper layer (**512 KB**) |
| bootlogo | mtd5 | 0xFD0000 | 0x020000 | boot logo |
| UDISK | mtd6 | 0xFF0000 | 0x010000 | misc flags |

Kernel cmdline: `root=/dev/mtdblock2 init=/pseudo_init ... gpt=1 mbr_offset=311296 cma=8M`.

## Root filesystem
- `/` is overlayfs: squashfs (mtdblock2, read-only) + jffs2 upper on mtdblock4 mounted at `/overlay/upperdir`.
- Anything written on the device persists **and shadows** the flashed rootfs. After a reflash, stale copies in the
  upper layer would hide the new files: check `/overlay/upperdir` (currently it should contain only `etc/resolv.conf`).
- The upper layer is only 512 KB: never install large files there (vdclient is 415 KB). Build them into the image.
- If a write fails half-way, delete the partial file **directly in `/overlay/upperdir`**. `rm` through `/` would
  create a whiteout that hides the rootfs copy too.
- Squashfs: stock squashfs-tools reject it (an `inodes` field moved in the superblock). `tools/Dockerfile` builds a
  patched mksquashfs/unsquashfs as Docker image `carplay-sqfs`.

## FEL (USB flashing mode)
- Hardware: short CLK (pin 6) to GND (pin 4) of the SPI flash at power-on, release after power-up. Needs the case open.
- **Software FEL (case closed):** write `0x5AA5A55A` to RTC GPR2 (`0x07000108`) and `reboot -f`; boot0 checks this
  magic and enters FEL; the flag self-clears. `reboot_efex` (mtd6 flag) does NOT work on this bootloader.
- [`xfel`](https://github.com/xboot/xfel) handles `version`, `spinor write/read`, `reset`.

## Board userland gaps
BusyBox here lacks `grep -A`, `head`, `find`, `free`, `rmdir`, `timeout`, `devmem`, `uptime`, and the `busybox`
applet list. Use `sed`/`awk` and the static tools in `device/` (devmem, evinject, i2cscan, pantest).
Static armv7 binaries are built in an `alpine:3.20` `linux/arm/v7` container (Docker Desktop on Apple Silicon).

## What strip.sh removes from the stock image
sdvcam (CarPlay/camera app), lylink* (Android Auto / CarPlay link), mdnsd, btstack/Bluetooth, tc_daemon/tca, OTA
tools, eyesee-mpp media libs, ALSA/Lua/OSD data, hostapd/udhcpd configs, the MPP/TCA/USB init scripts, all kernel
modules except bcmdhd, non-STA WiFi firmware, and every `usr/lib` library no remaining binary needs (checked
transitively; the build fails if anything is missing). Result: 2.1 MB rootfs (from 8.7 MB).

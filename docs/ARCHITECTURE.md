# Architecture: how the V831 screen works as a macOS display

This document explains the whole system end to end. Read it before changing anything.
Exact commands are in [OPERATIONS.md](OPERATIONS.md), board facts in [HARDWARE.md](HARDWARE.md),
the wire format in [PROTOCOL.md](PROTOCOL.md), and the reasons behind decisions in [HISTORY.md](HISTORY.md).

## 1. What the device is

An aftermarket "CarPlay screen": a 1600x600 touch panel driven by an Allwinner **V831** SoC
(one Cortex-A7 core at 1 GHz, 128 MB RAM, 16 MB SPI NOR flash) running a vendor Linux 4.9 with BusyBox.
Stock firmware ran CarPlay/Android Auto (`sdvcam`, `lylinkapp`, ...). We replaced the startup with our own
software. CarPlay, Android Auto, camera, Bluetooth and the vendor UI are deleted from the image.

The board now has one job: **show what the Mac sends and send touches back.**

```
            MAC (macOS)                                      SCREEN (V831, Linux)
 ┌──────────────────────────────────┐                ┌──────────────────────────────────┐
 │ CarPlay Monitor.app              │                │ S01app (init)                    │
 │   └ Terminal → mac/start.command │                │   └ dash_start.sh                │
 │        ├ server/dashd.py :8090 ◀─┼── /cmd poll ───┼──── command loop (httpc, 3 s)    │
 │        └ run_vdisplay.sh         │    (WiFi)      │      usbnet.sh (USB gadget)      │
 │            └ vdisplay :9100  ◀───┼── TCP dial ────┼──── vdclient                    │
 │               │ CGVirtualDisplay │  USB-NCM first │        │ draws into /dev/fb0     │
 │               │ ScreenCaptureKit │  WiFi fallback │        │ reads /dev/input/event4 │
 │               └ CGEvent (touch)  │                │        └ (GT911 touch)           │
 └──────────────────────────────────┘                └──────────────────────────────────┘
```

## 2. Board boot sequence

1. BootROM → boot0 → U-Boot → kernel → rootfs.
   - The rootfs is a squashfs at flash 0x2C0000. The vendor modified the superblock format, so it needs the
     patched squashfs-tools in `tools/Dockerfile`.
   - It is mounted under an overlayfs whose writable upper layer is a **512 KB** jffs2 (`/overlay/upperdir`).
2. `/etc/init.d/S01app` (our replacement for the vendor one, from `overlay/etc/init.d/S01app`):
   - sets the CPU governor to `performance`;
   - turns on the RTC 32 kHz clock output (`echo 0x07000060 1 > /sys/class/sunxi_dump/write`). The WiFi chip
     needs it, and stock did this in `bluetooth_init.sh`, which we deleted. Without it, **cold** boots have no WiFi;
   - starts `watchdog -t 2 /dev/watchdog`. The hardware watchdog (16 s) is armed by the bootloader and
     nothing else feeds it;
   - runs `/usr/bin/dash_start.sh &`.
3. `/usr/bin/dash_start.sh` (from `overlay/usr/bin/dash_start.sh`) reads `/etc/dashboard.conf`
   (`SSID PSK SERVER PORT`; SERVER = the Mac's WiFi IP), then:
   - **WiFi:** loads the `bcmdhd` driver (AP6334 module), runs wpa_supplicant and udhcpc;
   - **Command channel:** a background loop that, every 3 s, runs `httpc get SERVER PORT /cmd`.
     If the reply isn't empty, it runs it with `sh` as root and posts the output to `/result`;
   - **USB link:** after 10 s, runs `usbnet.sh`, guarded by `/usbnet.inprogress` (see section 7);
   - **Display:** `while :; do vdclient 169.254.100.2,$SERVER 9100; sleep 2; done`.
4. A 60 s check writes `/last_boot_fail.log` (in the overlay, so it survives a reboot) if WiFi never got an address.

## 3. The USB-C network link (`device/usbnet.sh`)

The USB-C port is OTG. We make the board a **USB device** that presents a **CDC-NCM network adapter**,
using Linux configfs gadgets. macOS supports NCM natively, with no driver.

- Only **one** gadget may exist on this kernel. A second `mkdir` returns "Out of memory", so the script
  reuses whatever gadget exists.
- The sunxi OTG manager switches to device role when you **read** `/sys/devices/platform/soc/usbc0/usb_device`.
  Writing does not work.
- Board address: `169.254.100.1/16`.
- `busybox udhcpd` hands the Mac exactly one lease, `169.254.100.2`, with no router or DNS option. The
  Mac never sends internet traffic over it, and the board can always reach the Mac at that address.
- Measured throughput: ~10.6 MB/s over USB vs ~0.65 MB/s over the board's WiFi.

## 4. The Mac side

### Launch and permissions
- `CarPlay Monitor.app` is a tiny AppleScript applet. It runs `open -a Terminal mac/start.command`.
  It is also the macOS **Login Item**.
- Everything must run **under Terminal**, because Terminal is the app holding the two TCC permissions:
  - **Screen Recording**, needed by ScreenCaptureKit;
  - **Accessibility**, needed to post mouse events.

  A launchd agent or another app would not have them.
- `start.command` starts `server/dashd.py 8090` (if nothing listens on 8090) and `mac/run_vdisplay.sh`
  (if it isn't already running). Both use `nohup`, so closing the Terminal window is fine.
- `run_vdisplay.sh` is a supervisor loop: it runs `./vdisplay >> vdisplay.log` and restarts it 2 s after it exits.
- `stop.command` kills the supervisor and `vdisplay`.

### `server/dashd.py` (command server, port 8090)
A stdlib-only Python HTTP server:

| Request | What it does |
|---|---|
| `GET /cmd` | Serves `server/cmd.sh` once, then renames it to `cmd.sh.sent` |
| `POST /result` | Appends the body to `server/results.log` |
| `POST /upload/NAME` | Saves the body to `server/uploads/NAME` |
| `GET /files/NAME` | Serves `server/files/NAME` (how binaries are pushed to the board) |

It is named "dashd" for historical reasons: it used to also render a dashboard image. That was removed on 2026-10-31.

### `mac/vdisplay.swift` (the display daemon, port 9100)

**Why it listens rather than dials:** macOS *Local Network privacy* silently blocks outbound LAN
connections from unsigned command-line tools. Inbound connections are allowed, so the board dials the Mac.

**Lifecycle**
- At start it only listens. No display exists yet.
- When the board connects (hello `VD01`), it creates the virtual display using the private
  `CGVirtualDisplay` API (header `mac/CGVirtualDisplay.h`, the same API BetterDisplay and others use):
  - name "V831 Display", vendor 0x1F3A, product 0x0831, serial 1;
  - one mode, 1600x600 @ 60 Hz, hiDPI off.

  It then sets that mode active (macOS otherwise picks 1280x480) and **never touches the display position**.
  macOS remembers the arrangement per vendor/product/serial; the user put it **below** the main display.
- It takes an IOPM "prevent idle system sleep" assertion while the display exists.
- When the board disconnects, it waits `VD_LINGER` seconds (default 60) for a reconnect. This covers a USB→WiFi
  switch and board reboots. If nothing reconnects, the process exits, so the display disappears with it, and the
  supervisor starts a fresh, display-less instance. That way there is **no ghost display** when the board is unplugged.

**Capture**
- ScreenCaptureKit streams the virtual display at up to 30 fps (BGRA, cursor included).
- Each frame carries a `dirtyRects` attachment.
- `FrameStore` keeps the latest frame and the accumulated dirty rects.

**Per frame (`handleClient` loop)**
1. Flow control: wait for a **credit**. Two credits exist, so at most 2 frames are unacknowledged:
   one transfers while the board decodes the other. The board acks each shown frame with its timings.
2. `mergeRects`: snap rects to a 16 px grid, merge near or overlapping ones, and fall back to full screen
   when there are more than 24 rects or more than 50% of the area changed.
3. `plan()`: compare the new frame with `sent` (what the board is showing).
   - **Scroll detection** (`detectScroll`). It hashes rows and votes using rows that are unique in the old
     frame, sampling slices at 0.25, 0.5 and 0.75 of the width. It finds the vertical shift, takes the longest
     matching run, and widens it sideways while ≥90% of rows still match. A match becomes a `copy` op ("move
     block from srcY to dst"), which the board does locally.
   - The remainder is diffed per column strip. Changed row bands, merged across gaps of 16 rows or less,
     become `tile` ops.
4. Encode each tile:
   - **raw** if it is at most 64x64x4 pixels;
   - otherwise **raw DEFLATE** (lossless, Apple's `.zlib`), unless it is more than N times bigger than
     the **JPEG** (ImageIO, quality `VD_QUALITY`, default 0.8). N is 4 over USB and 1.5 over WiFi.

   The result: text stays pixel-exact, and photos/video go as JPEG.
5. Send one `F` message, then update the stats line in `vdisplay.log` every 5 s (fps, KB/s, device timings, encoder counts).
6. The loop body runs inside `autoreleasepool`. Without it, ImageIO/NSData objects leak (~300 MB/min).

**Touch (`TouchInput`)**
- The board sends raw contact lists. All gesture logic lives on the Mac, so tuning it needs no board update.

| Contacts | Behaviour |
|---|---|
| 1, released without moving more than 12 px | Click |
| 1, moved more than 12 px | Drag (mouse down, moves, mouse up) |
| 1, held 0.6 s without moving | Right-click |
| 2 | Scroll-wheel events in pixel units |

- Coordinates map 1:1 into `CGDisplayBounds(displayID)`.
- On disconnect, `cancel()` releases a held button, so a drag can't stay stuck, but doesn't turn a half tap into a click.

**Environment knobs:** `VD_PORT`, `VD_QUALITY`, `VD_LOSSLESS_USB`, `VD_LOSSLESS_WIFI`, `VD_LINGER`, `VD_DEBUG`.

## 5. The board side display client (`device/vdclient.c`)

Usage: `vdclient [-1] HOST[,HOST...] PORT [TOUCH_EVDEV]`. It is static armv7, built against libjpeg-turbo and zlib.

**Connecting**
- Tries hosts in order (USB address first, then the Mac's WiFi IP), with a non-blocking connect and a 1.5 s timeout each.
- TCP keepalive (idle 4 s, interval 2 s, count 3) detects a dead USB link in about 10 s.
- When connected over a fallback host (WiFi), it probes the first host every 10 s and reconnects there when it answers.
- Not connected: the screen is filled with opaque black once (this also clears the boot logo), and it redials every 2 s.

**Drawing**
- A **shadow copy** of the screen lives in cached RAM. Reading `/dev/fb0` is very slow because it is
  uncached, so tiles are decoded into scratch memory, copied into the shadow, and written to fb0 in whole rows.
- Copy ops `memmove` inside the shadow.
- One `FBIOPAN_DISPLAY` per frame covers the bounding box of all rects. The sunxi driver only refreshes the
  rectangle passed in `var.reserved[0..3]` (empty = silent no-op). It rotates fb0 (1600x600 landscape) onto
  the portrait 600x1600 panel using the G2D engine, at ~7.6 ms per full screen.
- **Only one process may pan fb0.** Two concurrent panners can wedge the G2D IRQ until reboot: every pan then waits
  a 100 ms timeout, and `dmesg` shows "G2D irq pending flag timeout".
- After each frame it sends `A` with total/decode/copy/pan milliseconds.

**Touch**
- Finds the GT911 evdev by name (normally `/dev/input/event4`) and parses multitouch protocol A.
- Sends `T` with up to 2 contacts whenever the contacts change. A frame with 0 contacts means all fingers up.
- Pending touch events are flushed on connect.

## 6. Data paths in numbers

| Scenario | Rate | Notes |
|---|---|---|
| Scrolling a document | ~29 fps | ~13 KB per frame, thanks to copy ops |
| Typing, small UI changes | 14+ fps | |
| Whole screen of new text (worst case) | ~9–10 fps | Lossless; limited by board decode, not USB |
| Video | ~10 fps | Choppy, JPEG |
| USB → WiFi failover | ~10 s | Keepalive timeout, then redial |
| WiFi → USB return | ≤10 s | Probe interval |
| Board appears after Mac start | ≤5 s | |

Mac cost (measured on an M5 Ultra Mac Studio): `vdisplay` uses about 0.2% of one core idle and ~12% of one core while scrolling,
with 30–35 MB RSS. `dashd.py` uses ~15–23 MB. Effect on the GPU is negligible.
Board: `vdclient` RSS ~12 MB, and ~83–87 MB of RAM stays free.

## 7. Maintenance paths (case closed)

- **Remote command channel:** write `server/cmd.sh`. Within ~3 s it runs on the board as root, and the output lands
  in `server/results.log`. This is how everything is inspected and changed without opening the case.
- **Remote reflash** (`remote_flash.sh`):
  1. A command writes `0x5AA5A55A` to RTC general-purpose register 2 (0x07000108) and reboots.
  2. boot0 sees the magic and enters **FEL** (USB flashing mode).
  3. `xfel` writes the rootfs over the USB-C cable, reads it back, compares, and resets the board.
- **USB crash guard:** `dash_start.sh` creates `/usbnet.inprogress` before running `usbnet.sh` and deletes it afterwards.
  If the board crashed during USB setup (watchdog reboot), the next boot sees the file and skips USB, so it
  can't get stuck in a reboot loop. WiFi and the command channel stay up so it can be fixed remotely.
- **Restore to stock:** from FEL, `./flash.sh restore` writes the untouched 16 MB factory image from
  `$BACKUP_IMAGE` (your own dump, see config.env.example).

## 8. Files that make up the running system

| Where it runs | File | Source in repo |
|---|---|---|
| Board | `/etc/init.d/S01app` | `overlay/etc/init.d/S01app` |
| Board | `/usr/bin/dash_start.sh` | `overlay/usr/bin/dash_start.sh` |
| Board | `/usr/bin/usbnet.sh` | `overlay/usr/bin/usbnet.sh` (= `device/usbnet.sh`) |
| Board | `/usr/bin/vdclient` | `device/vdclient.c` → `overlay/usr/bin/vdclient` |
| Board | `/usr/bin/httpc` | `device/httpc.c` → `overlay/usr/bin/httpc` |
| Board | `/usr/bin/devmem` | `device/devmem.c` (used by remote_flash for software FEL) |
| Board | `/etc/dashboard.conf` | `overlay/etc/dashboard.conf` (from `dashboard.conf.example`; holds your WiFi password, git-ignored) |
| Mac | `vdisplay` | `mac/vdisplay.swift` + `mac/CGVirtualDisplay.h` |
| Mac | supervisor, start/stop | `mac/run_vdisplay.sh`, `mac/start.command`, `mac/stop.command` |
| Mac | command server | `server/dashd.py` |
| Mac | launchers | `CarPlay Monitor.app`, `Stop CarPlay Monitor.app` (made by `mac/make_launchers.sh`) |

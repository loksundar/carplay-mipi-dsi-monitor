# Project history and lessons learned

Chronological record of how this was built (2026-10-30 → 2026-10-31, with an AI coding agent doing the hands-on work),
including the mistakes, so nobody repeats them.

## Phase 1: getting in (2026-10-30)
- Dumped the 16 MB SPI NOR over FEL with xfel (hardware FEL: flash CLK→GND at power-on).
  That full image is the only way back to stock: keep it read-only, outside the repo, and never modify it.
- Mapped partitions (GPT + `mbr_offset`). The rootfs squashfs failed with stock tools: the vendor moved the
  `inodes` superblock field. Fixed with a patched squashfs-tools (`tools/Dockerfile`).
- Proved the toolchain with a **round-trip** (unmodified repack flashed and booted) before any change. Rule kept since:
  round-trip / verify before every flash.
- First flash "did nothing": CarPlay still booted. Lesson: verify which image is actually running.

## Phase 2: dashboard over WiFi (2026-10-30)
- Replaced the boot hook so `dash_start.sh` runs instead of `sdvcam`; a Mac HTTP server rendered a dashboard
  image that `fbdash` blitted to fb0.
- Boot loop (logo, blank, repeat): the hardware watchdog was no longer fed once sdvcam was gone → added
  `watchdog -t 2`.
- Screen stayed on the logo even though frames were drawn: `FBIOPAN_DISPLAY` is a no-op unless the dirty rect is in
  `var.reserved[0..3]`.
- SD-card config override never worked: the SD slot fails to initialise on this board.
- Added the **remote command channel** so later changes need no reflash.
- Stripped CarPlay/Android Auto/camera/BT/UI (`strip.sh`), rootfs 8.7 MB → ~2 MB.
- WiFi failed only on cold boots: the RTC 32 kHz clock output (enabled by the deleted bluetooth_init.sh) is needed by
  the WiFi module; warm resets kept the register set. Fixed in S01app. Lesson: test with a real power-off.
- Closed-case reflash: `reboot_efex` didn't work; found boot0 checks RTC GPR2 for 0x5AA5A55A → software FEL.
  `remote_flash.sh` was born. The user then closed the case.
- Touch: GT911 found on i2c-3; first "no touch" was the FPC cable inserted the wrong way round.

## Phase 3: extended macOS display (2026-10-30)
Research (see `docs/research/`) concluded: no HDMI input exists, so a "mini display" means the Mac
renders a virtual display and streams it. Chosen over a web browser on the device (too little RAM/CPU for a modern
browser; FBrowser research in `docs/research/fbrowser.md`).
- `CGVirtualDisplay` (private API) + ScreenCaptureKit on the Mac, `vdclient` on the board.
- New display defaulted to 1280x480 → set the native mode explicitly.
- **Mistake:** forced the display position to the left of the main display; the user had placed it below. Reverted.
  Rule: never touch the display arrangement.
- Decoding straight into fb0 took 231 ms–2 s per frame (uncached memory) → shadow buffer in cached RAM.
- WiFi too slow (~650 KB/s) → USB CDC-NCM link (~10.6 MB/s).
- Reusing the stock "probe" gadget (ffs instance) crashed the kernel → fresh gadget only, plus the crash guard.
- The Mac dialling the board hung: macOS Local Network privacy blocks outbound LAN connects from unsigned tools →
  the board dials the Mac; the board's DHCP gives the Mac a fixed USB address.
- vdisplay crashed with SIGTRAP in `_dispatch_semaphore_dispose`: a DispatchSemaphore created with value 2 and freed
  at a lower value traps → create at 0 and signal twice. Added the `run_vdisplay.sh` supervisor.
- Translucent Terminal windows defeated scroll detection (the blur changes every pixel) → tests use opaque windows.
- Full-width dirty rects hid scrolling → slice-based shift voting + per-column-strip diffs.
- Pans suddenly cost 100–200 ms: the G2D IRQ got wedged by **two processes panning at once** during testing; only a
  reboot clears it. Rule: one panner (deploy script stops the firmware loop first).
- Memory grew 101 MB → 1.1 GB in 3 min: per-frame ImageIO/NSData objects in a plain thread were never released →
  `autoreleasepool` around the frame body (flat at ~67 MB, later ~30 MB).
- Touch mapped to tap/drag/right-click/two-finger scroll; verified with injected events (`device/evinject.c`) and
  later with a real finger.

## Phase 4: polish (2026-10-31)
- Virtual display created lazily on first connection and removed 60 s after disconnect (no ghost display, no
  Dock/windows landing on an invisible screen). Idle-sleep assertion only while connected (replaced caffeinate).
- `start.command` made a Login Item at the user's request.
- **Dashboard removed** at the user's request: board shows black when no Mac; `fbdash` replaced by the minimal
  `httpc` (command channel only); `dashd.py` reduced to the command server (Mac RAM 51 → 23 MB). Board-side space
  saving ≈ 0 (both binaries ~46 KB, static libc dominates).
- **Mistake:** tried installing the new 415 KB vdclient into the 512 KB overlay → "No space left", half-written
  `/usr/bin/vdclient` in the upper layer. Did not reboot; deleted the partial files directly in `/overlay/upperdir`
  (restoring the rootfs copies), then shipped the files via a proper rebuild + remote reflash. Rule: big files only
  through the image.
- Scripts made location-independent; Docker builds stage under $TMPDIR (Docker Desktop doesn't share every host
  folder, e.g. /Applications). Verified a rebuilt image has identical contents to the flashed one.
- `CarPlay Monitor.app` / `Stop CarPlay Monitor.app` launchers; the Login Item points to the app.
- Fixed: a link drop mid-drag left the Mac's left mouse button pressed → `TouchInput.cancel()` on disconnect
  (tested: button down mid-drag, released after the drop).

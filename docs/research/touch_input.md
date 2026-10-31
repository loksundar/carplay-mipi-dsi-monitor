# Touch Input / Interactive Uses for the Hacked V831 1600x600 Touchscreen

Scope: local touch UI frameworks, the screen as a Stream Deck-style macro pad for a Mac, the screen as a touchscreen for a Mac (virtual) display, USB HID over FunctionFS, and Home Assistant control. Hardware: Allwinner V831 (1x Cortex-A7, 1.0 GHz), 128 MB RAM (about 91 MB free), 16 MB flash (about 8.7 MB free), vendor Linux 4.9, musl/busybox, fb0 1600x600 BGRA32 (needs FBIOPAN_DISPLAY with a dirty rect in var.reserved[0..3]), GT911 on /dev/input/event4, WiFi LAN, USB gadget functions available: NCM, mass_storage, FunctionFS.

Method note: I checked Linux 4.9 FunctionFS and composite source directly (downloaded from torvalds/linux tag v4.9). Facts marked "(not fetched this session)" come from general knowledge and should be verified before anyone relies on them.

Overall ranking (my synthesis, explained under each question below):
1. **Native C/LVGL Companion-Satellite client (Stream Deck replacement)**: highest value for the effort. Network-only, no kernel work, and the protocol is a small line-based text format.
2. **Local LVGL dashboard (HA tiles + Mac macro buttons) over a tiny TCP/HTTP bridge on the Mac**: the most flexible option. LVGL fits easily.
3. **Touch-to-Mac pointer injection over WiFi (CGEvent on the Mac)**: easy to build, but macOS treats touch as a single-pointer mouse, so there are no real multitouch gestures.
4. **USB HID gadget via FunctionFS (userspace HID daemon)**: technically supported by the 4.9 f_fs code, but untested on the sunxi UDC. A mouse or keyboard is likely to work. An absolute digitizer on macOS is uncertain without a driver.
5. **Qt / Slint / SDL2 locally**: possible, but worse fit for the flash and GPU constraints (details below).

---

## Q1. Local touch UI frameworks on fbdev + evdev (LVGL, Qt linuxfb, MiniGUI, Slint, SDL2)

### Takeaway
LVGL is the clear best fit: it is designed for kilobytes of RAM and hundreds of kilobytes of flash, and it ships Linux fbdev and evdev drivers. A custom flush callback can issue the device-specific FBIOPAN_DISPLAY with the dirty rect. Slint's embedded-Linux path expects OpenGL ES or KMS (the V831 display path here is plain fbdev with no usable GPU), and Qt is far too large for the roughly 8.7 MB of free flash.

### Cited Findings
- LVGL minimum requirements: more than 64 kB flash for the essentials (about 180 kB recommended), about 2 kB static RAM, a stack above 2 kB (8 kB recommended), and heap above 2 kB (48 kB recommended with many widgets), set by `LV_MEM_SIZE`. — [LVGL Requirements](https://lvgl.io/docs/open/introduction/requirements)
- A community measurement put LVGL at 170–295 kB flash and about 32 kB RAM. `-Os` plus LTO cut flash substantially. — [LVGL forum: flash footprint](https://forum.lvgl.io/t/flash-footprint-of-lvgl-is-high-how-to-reduce-it/6949)
- `lvgl/lv_port_linux` supports fbdev (`/dev/fb*`, overridable via `LV_LINUX_FBDEV_DEVICE`), DRM/KMS, SDL2, Wayland, X11 and GLFW. Input is evdev (`LV_LINUX_EVDEV_POINTER_DEVICE`, or autodiscovery). It builds with CMake and Kconfig and cross-compiles via `-DCMAKE_TOOLCHAIN_FILE` (`cmake/user_cross_compile_setup.cmake`). `-DLVGL_USE_INSTALLED=ON` skips the Kconfig and Python tooling. The README says nothing about musl or armv7. — [lv_port_linux](https://github.com/lvgl/lv_port_linux)
- A known LVGL pitfall: the input device must be registered after the display, or you get "no display registered hence can't attach the indev". — [LVGL forum: Update Framebuffer port](https://forum.lvgl.io/t/update-framebuffer-port-to-latest-version/5445)
- Slint's embedded Linux guidance expects a modern userspace with OpenGL ES 2.0+ or Vulkan. Its LinuxKMS backend tries a dumb-buffer display and falls back to linuxfb. Its MCU backend is software-only, with images and fonts embedded. — [Slint embedded platforms](https://snapshots.slint.dev/master/docs/slint/guide/platforms/embedded); [i-slint-backend-linuxkms swdisplay.rs](https://rust-digger.code-maven.com/src/i-slint-backend-linuxkms-1.8.0/display/swdisplay.rs)
- I found no V831-specific LVGL + GT911 port in Chinese sources. Generic Chinese porting notes say display (`lv_port_disp`) and input (`lv_port_indev`) are separate files you implement. — [CSDN-mirror article](https://blog.youkuaiyun.com/weixin_51954217/article/details/130164451)

### Inferences
- **Buffer math:** one full 1600x600x4 frame is 3.84 MB. LVGL in PARTIAL render mode with two buffers of 1/10 screen (about 384 kB each) needs under 1 MB. Even DIRECT or FULL mode with two full buffers (7.7 MB) fits in 91 MB. RAM is not the constraint.
- **Flash:** a static musl LVGL app with a few fonts should land around 0.5–1.5 MB, which fits in 8.7 MB.
- **Custom flush recipe:** the stock fbdev driver mmaps fb0 and copies areas. For this panel, write your own `flush_cb` (or patch `lv_linux_fbdev.c`) that does four things:
  1. Copy the area into the mmapped framebuffer. Configure `LV_COLOR_DEPTH 32`; BGRA matches LVGL's native ARGB8888 byte order on little-endian (B,G,R,A in memory).
  2. Accumulate the dirty-rect union.
  3. On `lv_display_flush_is_last()`, set `var.reserved[0..3]` to x, y, w, h (or whatever encoding the reverse engineering found) and call `ioctl(fd, FBIOPAN_DISPLAY, &var)`.
  4. Call `lv_display_flush_ready()`.
  This is roughly 40 lines of C.
- **Rotation and NEON:** the panel is natively landscape, so no rotation is needed. If you rotate, LVGL's software rotation costs CPU. LVGL has optional NEON blend paths (`LV_USE_DRAW_SW_ASM` = NEON); the exact config name may vary by version.
- **Touch input:** LVGL's evdev driver reads ABS_X/Y or ABS_MT_POSITION_X/Y and BTN_TOUCH, so it should work on event4. Raw GT911 ranges already match 1600x600, so calibration is likely unnecessary. LVGL is single-pointer only. Multitouch gestures would need custom evdev parsing.
- **MiniGUI 3.0** is already on flash (libminigui_ths + tslib), so its footprint costs nothing extra. But it is dated, its docs are mostly Chinese, and the vendor build is closed. Choose it only if you want to reuse stock UI resources.
- **Qt for Embedded (linuxfb)**: a minimal QtCore+QtGui+QtWidgets build is typically tens of MB (from general knowledge, not verified this session). That is too big for 8.7 MB flash unless it runs from a USB mass-storage or NFS chroot.
- **SDL2** with its fbcon video driver (SDL2's video driver was removed in later releases; KMSDRM needs DRM, which fbdev-only vendor kernels usually lack) is a poor fit. In general knowledge, SDL2 dropped fbcon in 2.0.x. Not verified this session.

### Gaps
- No published Slint linuxfb RAM/flash numbers for armv7 were found. It is also unconfirmed whether Slint's linuxfb fallback can be forced with no DRM present, and whether it would issue the custom FBIOPAN.
- No V831 + LVGL prior port was found on whycan, CSDN or Bilibili within the search budget. Searching whycan for "V831 LVGL" or "V833 lvgl" directly is still worth doing (the MaixII-Dock V831 community is the most likely place).

---

## Q2. Stream Deck-like macro pad for the Mac

### Takeaway
Bitfocus Companion's Satellite API is the best target. It is plain line-based TCP on port 16622 (or WebSocket on 16623), so a small C client can register a virtual surface, receive per-key RGB bitmaps (any square size, or non-square in advanced mode), and send KEY-PRESS. Companion on the Mac then runs the actions: its built-in macOS/OS integrations, HTTP calls to Hammerspoon or BetterTouchTool, shell commands, and more. The official companion-satellite client needs Node.js 24 on x64/arm64 Linux, so it cannot run on this armv7 device. A native C client is the way.

### Cited Findings
- Companion Satellite connects to Companion over the "satellite surface api", TCP 16622. It supports Companion 3.4.0+, runs headless on x64/arm64 Linux, needs NodeJS 24 for development, and has a REST config API on port 9999. — [companion-satellite](https://github.com/bitfocus/companion-satellite)
- **Protocol framing:** one line per message (`COMMAND ARG=VALUE`, ending `\n` or `\r\n`).
  - On connect the server sends `BEGIN CompanionVersion=... ApiVersion=1.x.y`, then (v1.10+) `CAPS`. WebSocket transport is on 16623 since Companion 3.5.
  - The client should `PING`/`PONG` about every 2 s and must answer server PINGs.
  - Unknown commands return `ERROR MESSAGE=...`.
  — [Satellite API](https://companion.free/for-developers/Satellite-API)
- **`ADD-DEVICE` (simple mode):** `ADD-DEVICE DEVICEID=x PRODUCT_NAME="..." KEYS_TOTAL=n KEYS_PER_ROW=m BITMAPS=<px> COLORS=hex TEXT=true`. `KEYS_TOTAL` is any integer ≥1 since API 1.5.1. `BITMAPS` sets a square pixel size (72 default). Advanced mode (1.9.0+) uses a base64 JSON `LAYOUT_MANIFEST` with per-control `bitmap {w,h}`, so non-square buttons are allowed. — [Satellite API](https://companion.free/for-developers/Satellite-API)
- **`KEY-STATE` from the server:** `KEY-STATE DEVICEID=x KEY=n BITMAP=<base64 raw RGB> COLOR=#rrggbb TEXT=<b64> PRESSED=...`. API 1.12.0+ can negotiate `BITMAP_FORMAT=png|webp` (sent as data URLs). Also available: `BRIGHTNESS DEVICEID=x VALUE=0..100`, and bitmap caching from 1.16. — [Satellite API](https://companion.free/for-developers/Satellite-API)
- **`KEY-PRESS` from the client:** `KEY-PRESS DEVICEID=x KEY=n PRESSED=true|false`. Since 1.6 KEY can be `row/col`. `KEY-ROTATE` handles encoders. — [Satellite API](https://companion.free/for-developers/Satellite-API)

### Inferences
- **Layout fit:** 1600x600 fits 8 columns x 3 rows of about 190 px tiles with gutters, or 16x6 at about 96 px. Using `BITMAPS=192` gives 192x192x3 = 110 kB raw per key, base64 about 147 kB. A full 24-key refresh is about 3.5 MB of text over WiFi, which is fine on change but heavy for animated buttons. Use `BITMAPS=96`–128 and scale up, or let the device render TEXT and COLOR itself.
- **Client size:** default raw-RGB mode needs no PNG decoder on the device. The client is about 300–600 lines of C: socket, line parser, base64 decode, RGB-to-BGRA blit with FBIOPAN, and evdev hit-testing. Use it standalone or inside an LVGL app with `lv_image` from RGB buffers.
- **How the Mac executes actions:**
  - Companion's own "generic/os" modules, HTTP requests, and shell commands (general knowledge, not fetched this session).
  - Hammerspoon `hs.httpserver` or `hs.urlevent` (`hammerspoon://` URLs).
  - BetterTouchTool webserver/URL scheme triggers.
  - `shortcuts run "<name>"` CLI or `shortcuts://run-shortcut?name=` URL.
  - `osascript` for AppleScript.
  - Keyboard Maestro web-server or URL triggers (`kmtrigger://`).
  None of these were verified this session; check each tool's docs.
- **Alternatives:**
  - The Touch Portal, Macro Deck, OpenDeck, deckmaster and streamdeck-ui clients are browser-, Android- or iOS-based, or drive physical Stream Decks. A browser is not viable on this device: there is no browser, and a WebKit build would not fit in flash.
  - Simplest no-dependency path: have the existing Mac Python server render a button grid (it already pushes frames), and the device sends back `{x,y,down/up}`. The Mac maps the hit to actions via Hammerspoon or `subprocess`. This reuses the existing pipe and needs no new protocol.
- **Prior art:** I found no published "Companion Satellite on an armv7 fbdev device in C" project within budget. Searching GitHub for "satellite api" C or ESP32 clients is advisable; ESP32 clients exist per community chatter but were not verified.

### Gaps
- No confirmation whether Companion's macOS build is current for Apple Silicon (very likely, but not fetched).
- Touch Portal and Macro Deck protocols were not researched in depth. Their device clients are apps or web, so I deprioritized them.

---

## Q3. Touch as Mac input (network-injected pointer for a Mac virtual display)

### Takeaway
The most reliable approach is to stream touch events over WiFi (UDP/TCP) to a Mac daemon. The daemon converts device coordinates into the global coordinates of the target display (including a virtual display) and posts CGEvent mouse events. Single-finger touch becomes move/click/drag, and two-finger touch becomes scroll. macOS has no native touchscreen support, so true multitouch gestures are not available, and the commercial drivers (UPDD) exist for exactly this reason.

### Cited Findings
- **Elo:** "MAC HID does not support Elo Touch Monitors, you will need to install the Elo Mac UPDD driver". It also says macOS has low-level HID support, but a touch driver is needed for the touchscreen to work properly and be aligned. — [Elo support](https://elosupport.elotouch.com/hc/en-us/articles/31649127329815-MAC-HID-Support-Driver-and-FW-Docs); [Elo cursor troubleshooting](https://elosupport.elotouch.com/hc/en-us/articles/31648526464791-How-do-I-troubleshoot-a-cursor-issue-on-a-Mac-computer)
- **Touch-Base (UPDD):** macOS does not support multi-touch devices unless the driver is installed, and some screens broke after macOS 10.15. — [Touch-Base hardware support](https://support.touch-base.com/Print50530.aspx)
- **RWTH "Touch Up":** USB HID touchscreens work with Windows out of the box, but "nothing happens" when connected to a Mac. — [RWTH Touch Up](https://hci.rwth-aachen.de/touchup)
- **Apple dev forums:** a developer reports macOS reading only the single-touch interface of a HID digitizer. A separate thread reports AppleUserHIDEventDriver not handling a HID multitouch click pad on macOS 14.7. — [Apple forums 829408](https://developer.apple.com/forums/thread/829408); [Apple forums 768586](https://developer.apple.com/forums/thread/768586)
- **Open-source macOS touch drivers using IOKit HID + CGEvent:** alax/TouchscreenDriver (Corsair Xeneon Edge) and osxhidtouch. — [TouchscreenDriver](https://gh.ali360.cloudns.ch/alax/TouchscreenDriver) (mirror of github.com/alax/TouchscreenDriver); [osxhidtouch](https://github.com/SRLive/osxhidtouch)
- **Weylus** (phone/tablet as touchscreen/stylus over the network) works best on Linux. Pen pressure/tilt are Linux-only, and on other OSes touch is basically mouse-like. — [Weylus README](https://github.com/H-M-H/Weylus/blob/master/Readme.md); [brightcoding summary](https://www.blog.brightcoding.dev/2025/09/26/weylus-transform-your-phone-or-tablet-into-a-fully-featured-graphic-tablet-or-touchscreen-for-your-computer)
- **Hammerspoon:** `hs.mouse.absolutePosition({x=,y=})` sets the pointer, and posting `hs.eventtap.event.newMouseEvent` mouseMoved/leftMouseDown/Up at a location works for synthetic events. — [hs.mouse docs](https://www.hammerspoon.org/docs/hs.mouse.html); [Hammerspoon PR 2144](https://github.com/Hammerspoon/hammerspoon/pull/2144); [vimouse.lua](https://github.com/tweekmonster/hammerspoon-vimouse/blob/master/vimouse.lua)

### Inferences
- **Recommended Mac side:** extend the existing Python server with pyobjc Quartz.
  - Pointer events: `CGEventCreateMouseEvent(None, kCGEventLeftMouseDown/Dragged/Up, (gx,gy), 0)` plus `CGEventPost(kCGHIDEventTap, e)`.
  - Two-finger scroll: `CGEventCreateScrollWheelEvent`.
  - Mapping: `CGDisplayBounds(displayID)` gives the origin and size of the virtual display the device mirrors, so `gx = origin.x + x/1600*w`.
  - The process needs the Accessibility permission. (Apple CGEvent API names from general knowledge; not fetched this session.)
- **Virtual display:** if the server already creates a 1600x600 virtual display (CGVirtualDisplay private API, as used by BetterDisplay or DeskPad), mapping is trivial. Otherwise map to a capture region.
- **Latency:** WiFi round trip plus frame streaming. Touch event packets are tiny, so UDP with sequence numbers works well. Send down/move/up, and coalesce moves to about 60 Hz.
- **Device side:** a 100-line C program reading event4 (handle ABS_MT_SLOT, ABS_MT_TRACKING_ID=-1 for lift, SYN_REPORT), sending over UDP.
- **Gestures:** pinch and rotate gestures cannot be synthesized via public CGEvent APIs. Approximate them with Cmd+scroll (zoom) or keyboard shortcuts.

### Gaps
- I did not verify current macOS 26 behavior for synthesized events on a virtual display created with the CGVirtualDisplay private API (the cursor should be able to warp there; untested).

---

## Q4. USB HID via FunctionFS without f_hid

### Takeaway
Yes, in principle. Linux 4.9's f_fs.c explicitly accepts a HID class descriptor (HID_DT_HID, 0x21) in the userspace-supplied descriptors. The composite core forwards interface-recipient control requests, including GET_DESCRIPTOR(Report, 0x22) with bmRequestType 0x81, to the FunctionFS function, which queues them to userspace as FUNCTIONFS_SETUP events. So a userspace "hid-daemon" can answer the report-descriptor request on ep0 and send reports on an interrupt IN endpoint. The kernel's own FunctionFS documentation uses "hid" with a `hid-daemon` as its example. The risks are the untested Allwinner UDC with FunctionFS and interrupt endpoints, and macOS's patchy handling of absolute digitizers. A relative mouse plus keyboard, or a single-touch "absolute mouse" (Generic Desktop / Pointer with absolute X/Y, like VirtualBox and KVM tablets use), is the safest descriptor choice.

### Cited Findings
- **HID descriptor accepted:** Linux v4.9 `drivers/usb/gadget/function/f_fs.c`, in `ffs_do_single_desc()`, has `case HID_DT_HID: pr_vdebug("hid descriptor\n"); if (length != sizeof(struct hid_descriptor)) goto inv_length;` (line ~1976). It also includes `<linux/hid.h>`. — [f_fs.c v4.9](https://raw.githubusercontent.com/torvalds/linux/v4.9/drivers/usb/gadget/function/f_fs.c)
- **Setup requests reach userspace:** `ffs_func_setup()` (line ~3157) maps `USB_RECIP_INTERFACE` requests to the function via `ffs_func_revmap_intf()`, then `__ffs_event_add(ffs, FUNCTIONFS_SETUP)` passes them to userspace. `ffs_func_req_match()` claims interface-recipient requests for that function. — [f_fs.c v4.9](https://raw.githubusercontent.com/torvalds/linux/v4.9/drivers/usb/gadget/function/f_fs.c)
- **Composite core forwards the report-descriptor request:** in v4.9 `composite.c`, the `USB_REQ_GET_DESCRIPTOR` handler only processes requests where `ctrl->bRequestType == USB_DIR_IN` (device recipient, 0x80). Others `goto unknown`, where "functions always handle their interfaces and endpoints" and requests go to `f->req_match`/`f->setup`. So a HID GET_DESCRIPTOR(Report) with bmRequestType 0x81 reaches f_fs. — [composite.c v4.9](https://raw.githubusercontent.com/torvalds/linux/v4.9/drivers/usb/gadget/composite.c)
- **Kernel docs:** FunctionFS's documentation literally uses HID as its example: `insmod g_ffs.ko ... functions=mtp,hid`, `mount -t functionfs hid /dev/ffs-hid`, `( cd /dev/ffs-hid && hid-daemon ) &`. — [Documentation/usb/functionfs.txt v4.9](https://raw.githubusercontent.com/torvalds/linux/v4.9/Documentation/usb/functionfs.txt); [functionfs.rst](https://git.zx2c4.com/wireguard-linux/tree/Documentation/usb/functionfs.rst)
- **No turnkey project found:** a Toradex forum user asked whether FunctionFS can implement HID and requested examples, with no answer in the thread. My searches found no public GitHub FunctionFS HID daemon. Known examples all use configfs `hid.usb0` / f_hid (needs `CONFIG_USB_CONFIGFS_F_HID`). — [Toradex community](https://community.toradex.com/t/composite-hid-device-linux/8278); [NVIDIA forum: CONFIG_USB_CONFIGFS_F_HID](https://forums.developer.nvidia.com/t/micro-b-usb-port-as-a-keyboard-hid-gadget/196807/9); [kernel gadget_hid docs](https://docs.kernel.org/usb/gadget_hid.html)
- **macOS digitizer support:** macOS has low-level HID support, but vendors require drivers for touchscreens to work and align correctly (see the Elo and Touch-Base citations in Q3). A developer reports macOS only talks to a digitizer's single-touch interface. — [Apple forums 829408](https://developer.apple.com/forums/thread/829408)

### Inferences
- **Implementation outline (no kernel rebuild):**
  1. `mkdir functions/ffs.hid` in the configfs gadget (NCM can stay alongside), then `mount -t functionfs hid /dev/ffs-hid`.
  2. Write v2 descriptors to ep0: an interface with bInterfaceClass=3, then the 9-byte HID descriptor (bDescriptorType 0x21, wDescriptorLength = report descriptor size), then one interrupt-IN endpoint (bInterval 1–8). Write FS and HS sets, then strings.
  3. Start the read loop on ep0. Answer FUNCTIONFS_SETUP for GET_DESCRIPTOR 0x22 by writing the report descriptor to ep0. Answer SET_IDLE/SET_PROTOCOL with a zero-length status (read 0 bytes for OUT, or ack), and stall others by reading/writing the wrong direction.
  4. Bind the UDC, then write reports to ep1.
  Note: in some kernels FunctionFS handles HID GET_DESCRIPTOR as "standard" while others need `FUNCTIONFS_ALL_CTRL_RECIP`. In 4.9, interface-recipient requests already reach userspace without that flag.
- **Descriptor choice for macOS:**
  - **Safest:** "absolute mouse" (Usage Page Generic Desktop, Usage Mouse/Pointer, Logical Min/Max 0..32767 X/Y, Input Data,Var,Abs, plus buttons). This is the descriptor that QEMU's usb-tablet and PiKVM use. macOS's generic HID driver normally maps it to absolute pointer moves, though it is unverified here.
  - **Pixel mapping:** absolute coordinates map to the whole main display, or possibly to the screen bounding box. Targeting a specific secondary or virtual display is unreliable, which is a limit compared with the network CGEvent approach.
  - **Digitizer:** a Digitizer usage page Touch Screen (0x0D/0x04) likely gets no pointer behavior without UPDD.
  - **Keyboard:** a keyboard interface (boot keyboard) is very likely to work, and gives media keys and macros without any Mac software at all (a "HID macro pad").
- **Allwinner UDC risk:** whether sunxi_usb_udc on this vendor kernel supports interrupt endpoints through FunctionFS and the required ep0 data stage from userspace is unknown. NCM working suggests bulk and interrupt (NCM uses an interrupt notify endpoint) are fine, which is encouraging. Test with a Linux host first, using `usbhid-dump`/`evtest`.
- **Fallback with zero kernel risk:** NCM is already available. Running the network touch protocol (Q3) over USB-NCM gives low-latency wired input without HID.

### Gaps
- No public, tested FunctionFS HID daemon was found to copy from. The nearest references are the kernel `tools/usb/ffs-test.c` and `ffs-aio-example` (not fetched this session), plus f_hid.c's setup handler logic to mirror.
- No source tested sunxi_usb_udc + FunctionFS + HID. No source confirmed macOS 15/26 handling of a stock absolute-mouse HID gadget, though PiKVM-style devices reportedly work with Macs (unverified).

---

## Q5. Home Assistant integration

### Takeaway
The lightest approach is a native client on the device. It can use the HA REST API (`GET /api/states/<entity>`, `POST /api/services/<domain>/<service>` with a long-lived token) or the WebSocket API (`/api/websocket`: auth with the token, `subscribe_events` or `subscribe_entities`, `call_service`) to drive LVGL tiles. Alternatively, keep the device dumb and let the Mac render the HA dashboard and stream it, as the frame server already does.

### Cited Findings
- **Long-lived access tokens** are created under Settings → Your profile → Security. — [codewords blog (May 2026)](https://www.codewords.ai/blog/home-assistant-long-lived-access-token)
- **WebSocket flow:** connect to `ws(s)://host:8123/api/websocket`, send an auth message with the long-lived token first, then subscribe. The home-assistant-js-websocket library exposes `subscribeEntities`; the raw protocol has `subscribe_events`. — [gist: HA websocket via node](https://gist.github.com/dkebler/fe872178e0de4a5874d6a6157b9f3537); [hass-websocket-client](https://pypi.org/project/hass-websocket-client)
- **Python wrapper example:** `client.call_service("light","turn_on")` with a long-lived token. — [hass-websocket-client](https://pypi.org/project/hass-websocket-client)

### Inferences
- **C on device:** for WebSocket, use a tiny client (e.g. wslay or a hand-rolled RFC 6455 client) plus cJSON or jsmn. For REST, use plain HTTP/1.1 over a socket, with no TLS if HA is on the LAN over http. With TLS, mbedTLS adds about 300–500 kB. Polling REST every 1–2 s for about 20 entities is trivial on a Cortex-A7.
- **Mac-proxy alternative (recommended for simplicity):** the existing Python server talks to HA (e.g. via hass-websocket-client) and exposes a tiny JSON or line protocol to the device. Secrets then stay on the Mac and the device needs no JSON or TLS. Companion also has an HA module, so the Companion Satellite client (Q2) can drive HA buttons with zero extra device code (Companion HA module from general knowledge; not verified).
- **ESPHome-style approaches** (ESPHome native API over protobuf) are not worth it here. The REST/WS path is simpler.
- **Streaming an HA web dashboard** rendered by headless Chrome on the Mac to fb0, with touches forwarded as clicks (via CDP `Input.dispatchMouseEvent`), reuses the frame pipe. It gives full Lovelace with no device-side UI work, at the cost of latency and Mac dependency.

### Gaps
- I did not fetch the official developers.home-assistant.io REST/WebSocket pages in this session. The exact message schemas (`call_service` fields `domain`, `service`, `service_data`/`target`; `subscribe_entities` compressed state format) should be verified there: https://developers.home-assistant.io/docs/api/websocket and https://developers.home-assistant.io/docs/api/rest

---

## Prior work on this device family (per coordinator instruction)

### Takeaway
One detailed public reverse-engineering write-up exists for an Allwinner V831 + AIC8800 + 16 MB NOR CarPlay unit, which is the same SoC and flash configuration as this device. It covers root via firmware upload and a CGI web shell, not touch or UI hacking. I found nothing on EEVblog "Hacking Podofo 10.26", whycan, CSDN or Bilibili about custom UIs or touch reuse on these screens within the search budget.

### Cited Findings
- A $50 CarPlay unit teardown: Allwinner V831, AIC8800 WiFi/BT, 16 MB SPI NOR. Root was obtained in under five hours through unauthenticated firmware upload over WiFi (a repacked image with a CGI web shell added to the startup script). The unit had a default root password hash, a hardcoded cloud key, and CORS open to all origins. — [Louis-E, "From Wi-Fi Access to Root: Reverse Engineering a $50 CarPlay Dongle" (Medium, via HN reader)](https://hn.jakechampion.name/reader/https://medium.com/@louis-e/from-wi-fi-access-to-root-reverse-engineering-a-50-carplay-dongle-a3fbeeeb0be9)
- MacRumors threads on Podofo/Cheerdriving units discuss custom firmware being for CarLinkIt adapters, not these screens, and report bricking risk from firmware updates. — [MacRumors thread p.284](https://forums.macrumors.com/threads/carplay-adapter-to-convert-to-wireless-carplay.2193978/page-284)

### Gaps
- The EEVblog "Hacking Podofo 10.26" forum thread did not surface in web search (the results were noise about the PoDoFo PDF library). Fetch eevblog.com/forum directly.
- No whycan or CSDN posts specific to V831 CarPlay screens (A3247, RC13, W903/W904, T86, CPAPAAMC) were found. The V831 community is centered on Sipeed MaixII-Dock (whycan "V831" board section), whose Tina SDK and LVGL demos may be reusable. That is unverified here and worth a targeted whycan search.

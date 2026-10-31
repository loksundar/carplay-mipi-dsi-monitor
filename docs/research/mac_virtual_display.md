# Mac-side: an extended virtual display streamed to the V831 1600x600 touch screen

Scope: what runs on the Apple Silicon Mac (create the virtual display, capture it, encode it, send it, inject touch), plus existing projects that could be reused. Research date: 2026-10-30. Device facts (Cortex-A7, 128 MB, 1600x600 BGRA fb, NCM/WiFi, GT911) come from the assignment and are not re-verified here.

## 1. Creating an extended virtual display on macOS (no dongle)

### Takeaway
macOS has no public API for this. Every dongle-free tool (open source or BetterDisplay) uses the private CoreGraphics `CGVirtualDisplay` classes. They work on macOS 14 through 26 today, but Apple can break them in any release. The simplest owned option is a small helper (Swift/ObjC, or Go via `go-macos/virtualdisplay`) that creates a 1600x600 display, optionally with HiDPI modes, and keeps it alive for as long as the process runs. BetterDisplay can do it without code, but arbitrary custom virtual-screen configurations need Pro.

### Cited Findings
- There is no public macOS API for creating virtual displays. `go-macos/virtualdisplay` calls the undocumented classes `CGVirtualDisplayDescriptor`, `CGVirtualDisplay`, `CGVirtualDisplaySettings` and `CGVirtualDisplayMode` from pure Go (purego, CGO off). The public alternative is a DriverKit extension that needs an entitlement granted by Apple. — [go-macos/virtualdisplay](https://pkg.go.dev/github.com/go-macos/virtualdisplay)
- go-macos/virtualdisplay details: BSD-3-Clause. Tested on macOS 26.6.2 (25G83) on an M4 Max. Spec fields are Width/Height (64–16384 px), RefreshRate (1–240, default 60) and a HiDPI flag that advertises Retina modes but does not switch into them. `Available()` is a runtime check for whether the API is present. The display lasts only as long as the creating process; the window server reclaims it on exit or crash. Changing a display's mode makes it impossible to remove until the process exits. Opening a display writes an ICC profile to `/Library/ColorSync/Profiles/Displays` that is never cleaned up. Removal is asynchronous (`WaitGone`). — [go-macos/virtualdisplay](https://pkg.go.dev/github.com/go-macos/virtualdisplay)
- Other projects that use CGVirtualDisplay: VirtualDisplayKit (Swift package; warns the private API may change), VoidDisplay (built with Xcode 26, targets macOS 15.6+), mac2mac/MacDisplay (CGVirtualDisplay + ScreenCaptureKit + HEVC, macOS 14+), OpenDisplay (macOS 14+). — [search summary: VirtualDisplayKit](https://gh.r-mj.com/xocialize/VirtualDisplayKit), [VoidDisplay](https://gh.r-mj.com/iamsyc/VoidDisplay), [mac2mac](https://github.com/kino-coder/mac2mac), [OpenDisplay](https://github.com/peetzweg/opendisplay)
- OpenDisplay creates an @2x (HiDPI) virtual display sized to the receiver's panel. Its private API declarations are in `Mac/CGVirtualDisplayPrivate.h`, a clean reference header. — [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)
- FluffyDisplay (tml1024): archived and read-only since 2024-08-28. A user issue reports its virtual display stopped working after the upgrade to macOS Sonoma 14.0. Treat it as dead. — [FluffyDisplay issue #19](https://github.com/tml1024/FluffyDisplay/issues/19); MacPorts still lists it: [ports.macports.org](https://ports.macports.org/port/FluffyDisplay/)
- FreeDisplay (MIT) is a free BetterDisplay alternative updated for macOS 26 Tahoe. It offers HiDPI virtual displays via CGVirtualDisplay (macOS 14+) and deliberately leaves out streaming/PiP. Its Tahoe fixes are UI/DDC related; it does not mention CGVirtualDisplay breaking. — [Akuwatoga/FreeDisplay](https://github.com/Akuwatoga/FreeDisplay)
- A developer's 2026 notes describe CGVirtualDisplay problems: on some workflows (especially right after a display reconfiguration) macOS silently moved the virtual display to another position, and workarounds failed on single-monitor setups. The notes label the build "macOS 16", which is odd, so treat this with caution. — [jorvik-software notes](https://jorvik-software.pages.dev/notes/2026/04/11/when-the-stars-align-redux)
- DeskPad (Stengo, MIT): a virtual monitor whose contents appear in a window on the main screen, made for screen sharing on calls. On first launch, Sequoia warns that it bypasses the system window picker. It may need Screen Recording permission. It is useful as a code reference (virtual display plus capture), not as an end product here. — [Stengo/DeskPad](https://github.com/Stengo/DeskPad), [podfeet review 2025](https://www.podfeet.com/blog/2025/03/deskpad/)
- BetterDisplay (waydabber) free tier: creating virtual screens and associating them with displays, custom scaled-resolution editing, resolution and refresh selectors. Pro only: "custom virtual screen configurations", HDR/high-refresh virtual screens, flexible HiDPI scaling, PiP, full-screen *local* streaming, stream crop/rotate/stretch, target frame-rate control for PiP/stream (v5). The wiki lists no network streaming feature. The free HTTP / URL-scheme integration is a control interface, not a stream. A 14-day trial includes all Pro features. — [BetterDisplay wiki: Free vs Pro](https://github.com/waydabber/BetterDisplay/wiki/List-of-free-and-Pro-features)
- BetterDisplay Pro is a perpetual licence; one source cites about $22 with at least a year of updates, while older articles say $15. Check betterdisplay.pro for the current price. — [betterdisplay.pro](https://betterdisplay.pro/), [DisplayBuddy comparison 2026](https://www.displaybuddy.app/displaybuddy-vs-betterdisplay)

### Inferences
- BetterDisplay's "streaming" only moves content between screens attached to the same Mac. It does not send pixels over a network, so it cannot feed the V831 by itself. At most, a BetterDisplay virtual screen plus our own ScreenCaptureKit capture would work. That saves writing the CGVirtualDisplay helper, but a 1600x600 custom aspect ratio (8:3) probably counts as a Pro "custom virtual screen configuration".
- Recommended approach: one Mac daemon that creates the 1600x600 display (use OpenDisplay's header or go-macos/virtualdisplay as the template), captures it, encodes it and serves the device. Because the display dies with the process, unplugging the device or stopping the daemon removes the extra screen cleanly. That is a feature.
- HiDPI choice: a 1600x600 framebuffer could be a 1600x600 @1x display (tiny but sharp UI) or an 800x300 @2x "looks like" mode rendered at 1600x600 backing pixels. go-macos notes that the HiDPI flag only advertises modes. Switching into them, and then being unable to remove the display until exit, is a known trap.
- Expect a breakage risk on every major macOS update. Gate startup on a runtime check (like `Available()`) and fall back to mirroring the main display or a window.

### Gaps
- No primary source confirms how CGVirtualDisplay behaves on macOS 26.x point releases beyond go-macos's single test (26.6.2) and FreeDisplay's Tahoe update.
- Not verified whether BetterDisplay free accepts an arbitrary 1600x600 virtual screen or only preset aspect ratios. The wiki wording ("custom virtual screen configurations: Pro") suggests Pro is needed.
- Chromeless and the Apple "VirtualDisplay" sample were not found. Apple publishes no official virtual display sample.

## 2. Capturing one specific display efficiently

### Takeaway
ScreenCaptureKit is the right tool. Use an `SCStream` with an `SCContentFilter` for the virtual display's `SCDisplay`, set `minimumFrameInterval` to cap the frame rate, and read the per-frame `dirtyRects` attachment so you only encode and send changed regions. It needs the Screen Recording (TCC) permission. CGDisplayStream is the older API and is deprecated in favour of ScreenCaptureKit (see Inferences).

### Cited Findings
- `SCStreamFrameInfo.dirtyRects` is an array of rectangles: the union of regions redrawn or moved in that frame. It is read from the sample buffer's attachments array. — [Apple docs: dirtyRects](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects.md), [.NET binding docs](https://learn.microsoft.com/en-us/dotnet/api/screencapturekit.scstreamframeinfokeys.dirtyrects?view=net-macos-26.4-10.0)
- WWDC22 "Take ScreenCaptureKit to the next level" shows `streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 15)` for 15 fps. It also shows reading `attachments[.dirtyRects]` to limit encoding and transmission to the changed areas. — [WWDC22 session 10155](https://developer.apple.com/la/videos/play/wwdc2022/10155/)
- OpenDisplay captures its CGVirtualDisplay with ScreenCaptureKit, and says the capture and streaming pipeline uses only public APIs. — [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)
- On macOS the cursor is not always part of the capture output. The ESP32 "flea cinema" project draws the cursor manually on macOS. — [Hackster](https://www.hackster.io/news/use-an-esp32-as-an-itty-bitty-second-monitor-for-your-pc-647b269b1d1b)

### Inferences
- ScreenCaptureKit also has `showsCursor`, `pixelFormat` (BGRA `kCVPixelFormatType_32BGRA`, or 420v/420f YUV for direct H.264 input), `width`/`height` and `queueDepth`, and it only delivers a frame when content changes (frames with status `.idle` carry no new pixels). This is from training knowledge; check the SCStreamConfiguration docs. BGRA from SCK matches the device's BGRA framebuffer byte order, so a raw or delta path needs no swizzle.
- Since about macOS 15, apps that keep Screen Recording permission get periodic re-confirmation prompts, and Sequoia shows a "bypassing the window picker" warning (as with DeskPad). Plan for a signed app bundle so the TCC grant sticks.
- CGDisplayStream deprecation: not fetched this session (training knowledge only).

### Gaps
- Whether `dirtyRects` are in display points or pixels on a HiDPI virtual display was not confirmed. Test empirically.

## 3. Existing second-screen software and protocols

### Takeaway
No ready-made product has a Mac server that also ships a Linux-framebuffer client for a weak ARM device. The closest reusable Mac-side codebase is **OpenDisplay** (GPL-3.0; MIT up to v0.4.x). It already does CGVirtualDisplay, ScreenCaptureKit, a VideoToolbox H.264/HEVC stream over TCP (USB or WiFi), and touch back as CGEvent, with a simple length-prefixed protocol. Deskreen and Weylus need a browser on the receiver; Spacedesk has no Mac server. VNC is the only generic protocol with a C client you could build for the device. But the built-in macOS server cannot be pointed at one display, so a custom RFB server per display is needed.

### Cited Findings
**OpenDisplay (best template)**
- GPL-3.0, © 2026 Philip Poloczek; releases up to v0.4.x stay MIT. 6.1k stars, 408 forks, 138 open issues and 47 open PRs at fetch time; the maintainer notes he is away until Nov 17, so reviews will be slow. Sending Mac: macOS 14+. — [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)
- Pipeline: CGVirtualDisplay @2x sized to the receiver panel, ScreenCaptureKit, VideoToolbox H.264/HEVC (real-time, no B-frames, TCP_NODELAY, 4:2:0, up to 18 Mb/s USB preset, frame-drop backpressure, keyframe recovery). Wire format: the receiver listens on TCP 9000 and the Mac connects. Each message is a 4-byte length plus an Annex B frame; control messages (hello/touch/scroll) are JSON; the spec is in PROTOCOL.md. Touch is injected via CGEvent (click, drag, scroll), which needs the Accessibility permission. — [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)
- Transport is usbmux (USB) or Wi-Fi over a single TCP connection; claims up to 60 fps over USB. Article dated 2026-08-26. — [Newsshooter](https://www.newsshooter.com/2026/08/26/opendisplay-gives-your-mac-a-real-extended-display-using-an-apple-device-you-already-own/)
- Related: OpenSidecar (CGVirtualDisplay, private API) — [peetzweg.github.io/opensidecar](https://peetzweg.github.io/opensidecar/); mac2mac/MacDisplay (CGVirtualDisplay + SCK + hardware HEVC, Mac to Mac) — [kino-coder/mac2mac](https://github.com/kino-coder/mac2mac)

**Deskreen**
- Free and open source; any device with a web browser on the LAN becomes a second screen (WebRTC). A true extended desktop needs a virtual display adapter or dummy plug; on macOS the usual suggestion is BetterDisplay. — [Linux Uprising](https://www.linuxuprising.com/2021/01/deskreen-makes-any-device-with-web.html), [deskreen.com](https://deskreen.com/), [GitHub discussion #86](https://www.github.com/pavlobu/deskreen/discussions/86), [AlternativeTo](https://alternativeto.net/software/deskreen/about)
- Most sources are from 2020–2022.

**Weylus / Spacedesk / Side Screen**
- Spacedesk is not available as a Mac server; its driver is Windows-only and Mac is only a client. — [AlternativeTo](https://alternativeto.net/software/spacedesk/?platform=mac), [linuxfr review](https://linuxfr.org/users/usawa/journaux/utilisez-une-tablette-ou-tout-autre-ordinateur-comme-second-ecran.epub)
- Weylus lists Mac/Windows/Linux and targets tablets and phones through a browser. "Side Screen" is listed as a free, open-source Mac alternative for Android receivers. — [AlternativeTo](https://alternativeto.net/software/spacedesk/?license=free)

**Sunshine/Moonlight forks with macOS virtual displays**
- The Lumen forks of Sunshine create a virtual display matching the client's requested resolution and refresh rate when a client connects, and remove it on disconnect. They require macOS 14+ and Apple Silicon. — [saxlamen/Lumen](https://github.com/saxlamen/Lumen), [trollzem/Lumen](https://github.com/trollzem/Lumen)
- Upstream Sunshine on Linux/KMS ignores Moonlight's display selection; only the configured `output_name` is streamed. — [LizardByte discussion #994](https://github.com/orgs/LizardByte/discussions/994)

**VNC on macOS**
- The built-in screensharingd serves all monitors; "Displays have separate Spaces" does not restrict it. A user only managed to serve one monitor with RealVNC Connect. — [Apple Discussions](https://discussions.apple.com/thread/8199989?page=1)
- Vine Server (OSXvnc) serves only the main display (the one with the menu bar), and a change needs a server restart. — [Eggplant forum](https://forums.eggplantsoftware.com/t/selecting-a-monitor-in-2-monitor-setup/1725), [Softpedia](https://mac.softpedia.com/get/Internet-Utilities/OSXvnc.shtml)
- macVNC (GPL-2.0): command-line server that captures a specific window by window ID, needs Screen Recording and Accessibility. — [macVNC](https://gh.r-mj.com/therapys/macVNC)

**Microcontroller and e-ink second screens (protocol references)**
- ESP32 "flea cinema" (Tucker Shannon): a Python host captures the screen, scales it to 135x240, and sends only changed pixels; TFT_eSPI on the device; under 100 ms latency on a good network; up to about 60 fps when little changes, about 5 fps with fast motion; draws the cursor itself on macOS. — [Hackster](https://www.hackster.io/news/use-an-esp32-as-an-itty-bitty-second-monitor-for-your-pc-647b269b1d1b), [CircuitDigest](https://circuitdigest.com/news/using-an-esp32-as-a-small-wireless-desktop-monitor)
- arduinoVNC (Links2004; forks by moononournation and bitbank2) is an RFB client for ESP8266/ESP32 supporting Hextile, ZLIB and ZRLE; one copy of the README lists TIGHT as unsupported. An ESP32 thin-client build got only about 6–7 fps with Hextile when part of the screen kept changing, at a little over 1 MB/s. — [Links2004/arduinoVNC](https://www.github.com/Links2004/arduinoVNC), [moononournation fork](https://github.com/moononournation/ArduinoVNC), [Instructables Arduino Thin Client](https://www.instructables.com/Arduino-Thin-Client)
- RabbitInk drives e-ink modules with IT8915 USB controllers as a low-latency monitor, but only on Linux/X11 (it captures a virtual monitor). — [blahgeek/rabbitink](https://github.com/blahgeek/rabbitink)
- libvncclient decodes Tight/JPEG straight into the framebuffer via TurboJPEG, and has experimental H.264 framebuffer decoding (VA-API). — [libtdevnc rfbclient.h history](https://scm.trinitydesktop.org/gitea/TDE/libtdevnc/commits/branch/master/rfb/rfbclient.h)

### Inferences
- Duet, Luna Display, Splashtop Wired XDisplay and Sidecar are closed, paired-client products (iPad/Android/Mac receivers). None publishes a protocol or a Linux framebuffer client, so they are not reusable here. Not researched in depth this session.
- Practical reuse paths:
  1. **Fork OpenDisplay's Mac sender** (take the v0.4.x MIT tag if GPL is a problem). Swap the iOS receiver for a C client on the V831: keep the 4-byte length-prefix framing and JSON touch messages, and either decode H.264 on the device (only if the V831's video engine or a software decoder can manage 1600x600) or change the Mac encoder to JPEG or delta tiles.
  2. **Custom RFB (VNC) server bound to the virtual display**, built on SCK plus libvncserver, with a small libvncclient-based framebuffer client on the device. RFB gives pointer events (touch) and incremental updates for free. ZRLE/Tight-JPEG are well understood.
  3. **Extend the existing HTTP raw-frame server** into a push protocol over TCP with dirty-rect tiles (the "flea cinema" style). Least code, and it fits the current device client.
- Deskreen/Weylus are out because the device has no browser, and a WebRTC/H.264 browser stack will not fit in about 91 MB on an A7.

### Gaps
- OpenDisplay's PROTOCOL.md was not fetched; the exact JSON touch schema is unknown.
- Exact repo URL for Tucker Shannon's ESP32 project not confirmed.
- No current (2026) confirmation of whether RealVNC Connect on macOS can serve a *virtual* display specifically.

## 4. Encoding options and bandwidth for 1600x600

### Takeaway
Raw BGRA at 1600x600 is 3.84 MB/frame. That is fine over USB-NCM at a few fps but too much for 30 fps over WiFi. For a single A7 core, the sweet spot is probably **dirty-rect tiles** (raw, RGB565 or zlib/LZ4) for static desktop content, plus **JPEG tiles** for large changing areas. H.264 via VideoToolbox is trivial on the Mac (real-time, baseline, no B-frames), but decode cost on the V831 is the deciding factor and belongs to the device-side research.

### Cited Findings
- VideoToolbox low-latency settings: `kVTCompressionPropertyKey_RealTime` = true plus `PrioritizeEncodingSpeedOverQuality` = true is Apple's suggested low-latency profile. Hardware H.264 favours quality by default, and RealTime is advisory. FFmpeg's patch for the speed property reported a 50–70% speedup. — [xamarin VideoToolbox header diff](https://github.com/xamarin/xamarin-macios/wiki/VideoToolbox-macOS-xcode13.3-beta1), [FFmpeg-cvslog](https://ffmpeg.org/pipermail/ffmpeg-cvslog/2022-May/132303.html)
- Disable frame reordering (no B-frames) for lowest latency; Baseline profile for compatibility (secondary source). — [skills.lc VideoToolbox H.264](https://www.skills.lc/co-labs-co/context-harness-skills/co-labs-co-context-harness-skills-skill-videotoolbox-h264-encoding-skill-md)
- OpenDisplay's production settings: real-time, no B-frames, 4:2:0, 18 Mb/s top USB preset, frame-drop backpressure, keyframe recovery. — [opendisplay](https://github.com/peetzweg/opendisplay)
- For comparison, NXP forum users saw software JPEG decode at about 5 fps for 1080p on an i.MX8 (Cortex-A35/A53 class; more capable than one A7). — [NXP community](https://community.nxp.com/t5/i-MX-Processors/v4l2jpegdec-C-example/m-p/951661)

### Bandwidth math (computed, not sourced)
| Format | Bytes/frame | 5 fps | 15 fps | 30 fps |
|---|---|---|---|---|
| Raw BGRA32 (1600x600x4) | 3.84 MB | 19.2 MB/s (154 Mbit/s) | 57.6 MB/s (461 Mbit/s) | 115 MB/s (922 Mbit/s) |
| RGB565 | 1.92 MB | 77 Mbit/s | 230 Mbit/s | 461 Mbit/s |
| Dirty tiles, e.g. 10% changed, BGRA | ~0.38 MB | 15 Mbit/s | 46 Mbit/s | 92 Mbit/s |
| JPEG full frame (assume ~100–200 KB at q~75 for desktop UI) | 0.1–0.2 MB | 4–8 Mbit/s | 12–24 Mbit/s | 24–48 Mbit/s |
| H.264 (OpenDisplay-like 2–18 Mbit/s) | — | — | — | 2–18 Mbit/s |

### Inferences
- The device's current approach (full raw frame every 30 s over HTTP) is 3.84 MB per update. Keep raw for the very first frame and keyframes, then send only dirty rects from SCK. For typical desktop use (cursor, text edits) the changed area is a small fraction of the frame, so even raw tiles fit WiFi at 15+ fps.
- JPEG decode is the CPU limit on the device: 0.96 MP per full frame. A rough estimate for libjpeg-turbo NEON on one 1 GHz A7 is tens of ms per full frame (unverified), so roughly 10–20 fps full-frame. Decoding only dirty tiles scales down from there. Encode on the Mac with ImageIO/VideoToolbox (`kCMVideoCodecType_JPEG` is hardware-accelerated on Apple Silicon) or libjpeg-turbo; all are cheap.
- The H.264 viability depends on whether the V831's Cedar VE exposes a usable H.264 *decoder* under the vendor 4.9 kernel/musl (the V831 is mainly marketed as a camera/encode SoC). Software decode of 1600x600 on one A7 is likely only a few fps. This is for the device-side researcher.
- Dirty rects plus LZ4/zlib on BGRA is the most CPU-friendly for the device (memcpy-like decode) and suits mostly static UI. USB-NCM (likely tens of Mbit/s or more in practice) gives room for this; over 2.4 GHz WiFi, use compression.

### Gaps
- No measured libjpeg-turbo or H.264 decode benchmarks for a Cortex-A7 at 1 GHz at this resolution were found.
- No source found on the V831's hardware H.264/JPEG *decode* support (searches on whycan and CSDN terms returned nothing relevant).

## 5. Input path: GT911 touch back to the Mac

### Takeaway
Send absolute touch coordinates (0–1599, 0–599) from the device and map them to the virtual display's global bounds (`CGDisplayBounds(displayID)` origin plus scaled offset). Then post `CGEvent` mouse-moved/down/dragged/up and scroll-wheel events. This needs the Accessibility permission for the Mac daemon. OpenDisplay already implements exactly this (tap = click, drag, two-finger scroll).

### Cited Findings
- OpenDisplay injects touch as CGEvent click/drag/scroll and needs Accessibility "for touch/scroll input". Control messages are JSON over the same TCP socket. — [opendisplay](https://github.com/peetzweg/opendisplay), [Newsshooter](https://www.newsshooter.com/2026/08/26/opendisplay-gives-your-mac-a-real-extended-display-using-an-apple-device-you-already-own/)
- macVNC (an RFB server) needs Accessibility for input injection, which shows that the VNC pointer-event route uses the same permission. — [macVNC](https://gh.r-mj.com/therapys/macVNC)

### Inferences
- With a HiDPI (@2x) virtual display, divide device pixel coordinates by the backing scale to get global points. With @1x, the mapping is 1:1 plus the display origin. Recompute after any display rearrangement (see the reported position drift in §1).
- Using RFB as the transport gives PointerEvent (x, y, button mask) for free; a custom protocol only needs {type, id, x, y} messages.

### Gaps
- Multi-touch gestures (pinch-to-zoom) cannot be injected as real trackpad gestures through public CGEvent APIs. Not researched further.

## Prior work on this device family (coordinator request)

### Takeaway
No public project was found that turns a V831-based CarPlay screen (Podofo, Lamtto, Carpuride, T86) into a PC or Mac extended monitor. The only related public reverse engineering is a V831 CarPlay *dongle* root write-up and MacRumors notes on Podofo firmware.

### Cited Findings
- Reverse engineering of a $50 V831-based CarPlay dongle ("Herilary C-4"): firmware filesystem extracted and root obtained; AIC8800 WiFi/BT and a 16 MB Winbond SPI NOR. — [Medium: From Wi-Fi Access to Root](https://medium.com/@louis-e/from-wi-fi-access-to-root-reverse-engineering-a-50-carplay-dongle-a3fbeeeb0be9)
- MacRumors users say Podofo units appear to be CheerDriving rebrands with the same firmware, updated by microSD. — [MacRumors thread p.276](https://forums.macrumors.com/threads/carplay-adapter-to-convert-to-wireless-carplay.2193978/page-276)
- Security talks on third-party CarPlay adapters (hack.lu 2025, CCC "Pwn My Ride") exist but are not about display reuse. — [hack.lu 2025](https://pretalx.com/hack-lu-2025/speaker/LKBLKC), [media.ccc.de](https://app.media.ccc.de/v/god2025-56485-pwn-my-ride-jailbreaking-c)

### Gaps
- The EEVblog thread "Hacking Podofo 10.26" did not appear in search results. Searches for V831 "副屏/扩展屏" (Chinese for "secondary screen / extended screen") on whycan/CSDN returned only generic framebuffer docs.

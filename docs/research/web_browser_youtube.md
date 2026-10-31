# Web browsing and YouTube playback on the V831 (128MB RAM, fbdev, no GPU)

Scope: whether a real browser engine can run on the device (Allwinner V831, 1x Cortex-A7 @1.0GHz, ~91.5MB free RAM, no swap, 16MB NOR with ~8.7MB free, tmpfs ~61MB, fb0 1600x600 BGRA, no GPU), the most workable engine, YouTube options, and a remote-rendering alternative. Research done 2026-10-30. About 17 searches, so coverage is broad but shallow in places. See the Gaps sections.

## Q1. WPE WebKit + Cog: can it render to a plain framebuffer without EGL/GPU? Footprint? Buildroot?

### Takeaway
WPE now uses Skia, which has an explicit CPU-only rendering mode. But the backends (WPEBackend-fdo, Cog, and the newer WPE Platform API) are built around EGL/dmabuf. CPU-only/SHM paths exist but are aimed at headless or GStreamer use, not plain fbdev, and no source shows a working Cog-to-fbdev setup without a GPU. The only footprint numbers are old (about 2017): a roughly 40MB image and about 100MB RAM. Even then that would not fit in 91.5MB with a modern multi-process WebKit. Verdict: not feasible in practice on this device. At best a long-shot engineering project.

### Cited Findings
- WebKitGTK and WPE replaced Cairo with Skia for 2D rendering. Igalia's Skia branch was "upstreamable" in Feb 2024 and then landed in main. — [Igalia blog (carlosgc)](https://blogs.igalia.com/carlosgc/?p=1016)
- The WPE env-var docs list `WEBKIT_SKIA_ENABLE_CPU_RENDERING`, which disallows GPU rendering. `WEBKIT_SKIA_GPU_PAINTING_THREADS=0` turns off GPU tile painting, but the GPU may still be used for filters. CPU painting threads default to half the cores, capped at 8. — [WPE environment variables](https://people.igalia.com/aperez/Documentation/wpe-webkit/environment-variables.html)
- In GStreamer's wpesrc, SHM export once still required a valid EGLDisplay. WPEBackend-FDO 1.8.x was set to drop that requirement "allowing wpesrc to be used without GPU". Headless support exists from WPEBackend-FDO 1.6.x, with `LIBGL_ALWAYS_SOFTWARE` suggested for software use. — [gst-plugins-bad MR 1164](https://gitlab.freedesktop.org/gstreamer/gst-plugins-bad/-/merge_requests/1164); [MR 1040 "wpe: Add software rendering support"](https://gitlab.freedesktop.org/gstreamer/gst-plugins-bad/-/merge_requests/1040)
- 2019: Cog with fdo/swrast/fbdev failed with EGL_NOT_INITIALIZED (missing EGL_WL_bind_wayland_display). The thread says the bigger open problem was "how to handle the shm buffer in Cog". — [webkit-wpe mailing list, Jul 2019](https://lists.webkit.org/pipermail/webkit-wpe/2019-July/000202.html)
- The newer WPE Platform API "headless" platform has work items to implement `get_egl_display` and build its format list from the EGL display, so it is still EGL-centric. — [WebKit Bugzilla 280263](https://29639-bug-104426-attachments.webkit.org/show_bug.cgi?id=280263)
- The only concrete WPE footprint figures are an Igalia/GENIVI deck from about 2017: a functional Raspberry Pi image of ~40MB and memory "limited to ~100MB for a standard setup". These are dated and unverified for current releases. — [GENIVI open source browser space (PDF)](https://wiki.covesa.global/download/attachments/364316/GENIVI-open-source-browser-space.pdf?api=v2)
- Igalia says WPE's minimal dependencies keep the footprint small for low-end devices, but gives no numbers. — [Igalia WPE project page](https://www.igalia.com/project/wpe)
- 2022 mailing-list report: WPE-Android used more memory than Android WebView. Igalia said memory optimization was planned for later. — [webkit-wpe, Aug 2022](https://lists.webkit.org/pipermail/webkit-wpe/2022-August/000540.html)
- Jan 2026: WebKit memory-footprint accounting was unified across GTK/JSC/WPE and now uses /proc/self/statm. This changes how usage is measured, not how much is used. — [Igalia WebKit WIP #53](https://blogs.igalia.com/webkit/blog/2026/wip-53/)

### Inferences
- A CPU-only WPE path would be: WPE Platform headless (or fdo exportable SHM) plus Skia CPU, then a custom view backend that copies the SHM buffer into fb0 and calls FBIOPAN_DISPLAY. That means writing a Cog platform plugin or a small custom launcher, which is real engineering. It is also unclear whether current WPE builds still pull in Mesa/EGL as a hard link-time dependency. Bundling Mesa llvmpipe/softpipe would add several MB, and llvmpipe on one A7 would be very slow.
- WPE runs at least two processes (UI process plus WebProcess, plus NetworkProcess). A modern WebKit with JSC typically has tens of MB RSS per web process before any page content. With ~91.5MB free and no swap, a real-world page (dashboard JS frameworks, let alone YouTube) would likely OOM. This is an engineering judgment, not a measured number.
- Storage: the WPE libraries (libWPEWebKit, ICU data, GStreamer, etc.) would have to live in tmpfs as an xz squashfs. A WPE build would probably be at least as large as the measured QtWebKit 5.212 set (~82MB raw / ~20MB xz from prior findings). That fits in the 61MB tmpfs, but squashfs pages are cached in RAM, so it competes with the browser's heap.

### Gaps
- No source shows a working Cog/WPE on Linux fbdev with no EGL at all in 2024-2026. I did not open Cog's GitHub issues or the Buildroot `wpewebkit`/`cog` package files, so Buildroot details (versions, which platforms are selectable, whether a headless option exists) are unverified. The `package/wpewebkit` and `package/cog` dirs in Buildroot master would be the place to check.
- No measured WPE RSS numbers on 128MB/256MB boards from 2023 or later.

## Q2. Lightweight engines (NetSurf fb, Links2 -g, Dillo, Ultralight, Servo, litehtml): good enough for a static dashboard?

### Takeaway
NetSurf's framebuffer frontend is purpose-built for this case: no toolkit, draws directly to fbdev via libnsfb, supports 32bpp, and has been used for embedded kiosks. JavaScript is incomplete or often not compiled into fb builds. It is a good fit for a server-rendered static HTML/CSS dashboard with meta-refresh, and it fails on JS-driven dashboards such as Home Assistant Lovelace. The other options were not researched in depth in this pass.

### Cited Findings
- The NetSurf framebuffer port (since 2008) uses no GUI toolkit, draws its own pointer, scrollbars and widgets, and "has been used to create a web kiosk on embedded systems". — [NetSurf (Wikipedia)](https://EN.wikipedia.com/wiki/NetSurf)
- NetSurf 3.4 (2016) first shipped Duktape JS, but JS was "disabled by default as the support is incomplete". 3.10 (2020) updated Duktape to 2.4.0. Latest release found was 3.11 (Dec 2023). — [NetSurf (Wikipedia)](https://EN.wikipedia.com/wiki/NetSurf)
- A Tiny Core user found a netsurf-fbdev build with no JavaScript handler compiled in (anecdotal, version unclear). — [Tiny Core forum](https://forum.tinycorelinux.net/index.php/topic,22451.25.html)
- The NetSurf fb frontend glyph cache (`fb_font_cachesize`) defaults to 2048KB. libnsfb supports 8/16/24/32bpp surfaces. The docs (2010) say the frontend lacks functionality compared to native ports. — [using-framebuffer docs (mirror)](https://vcs.vera-visions.com/eukara/WebSurf/src/commit/4a53631c7fc2edc490c86149202e4fe2008054df/docs/using-framebuffer.md); [libnsfb port description](https://openports.pl/path/www/netsurf/libnsfb)

### Inferences
- NetSurf-fb is the most feasible on-device HTML engine for a dashboard you control: render HTML/CSS on the Mac or HA side with no JS, auto-refresh, and large touch targets. Two integration risks to check. (1) libnsfb's linux surface probably does not issue FBIOPAN_DISPLAY after each update, so it will likely need a small patch, the same issue as Qt linuxfb. (2) GT911 touch has to come through libnsfb's linux evdev input, which likely needs absolute-coordinate handling.
- From general knowledge, not sourced in this pass (verify before relying on it): Links2 -g has an fbdev driver but no JS and weak CSS. Dillo needs FLTK, which needs X11 (no native fbdev in current FLTK). Ultralight is proprietary, x86/ARM64-oriented, and has no armv7 Linux build. Servo is far too heavy for 128MB. litehtml is just a layout library (you would supply the drawing and networking yourself), workable but a custom project.

### Gaps
- No measured NetSurf-fb RSS numbers found. No current confirmation of whether NetSurf 3.11 fb builds enable Duktape by default.
- Links2/Dillo/Ultralight/Servo/litehtml footprints were not researched with sources in this pass.

## Q3. Chromium / CEF / Electron / WebView on 128MB ARMv7

### Takeaway
Not feasible. Chromium's own startup memcheck warns below 1GB, and 512MB Pi Zero users report crashes, segfaults or failure to start. A 128MB device with no swap is more than an order of magnitude short.

### Cited Findings
- On a 512MB Pi Zero 2 W, Chromium shows a dialog saying it is not recommended to run on less than 1GB RAM. `--no-memcheck` suppresses it. — [FullPageOS PR #672](https://github.com/guysoft/FullPageOS/pull/672)
- A Pi Zero user found Chromium "requires much more memory than 512MB" plus 100MB swap. — [balena forums](https://forums.balena.io/t/increase-swap-size/200219)
- Legacy Chromium on a low-RAM Pi "segfaults frequently due to the limited amount of RAM". Another user reports Chromium "won't even start, not enough RAM" on a Zero 2W and Epiphany (WebKitGTK) as "very slow". — [MagicMirror forum](https://forum.magicmirror.builders/topic/18200.rss); [r/raspberry_pi](https://redlib.hbubli.cc/r/raspberry_pi/comments/1kzy6gn/raspberry_pi_zero_2w_for_display/mvalch0)
- Qt WebEngine (Chromium) generally cannot draw to a Linux framebuffer because it relies heavily on OpenGL. — [Qt forum](https://forum.qt.io/topic/48597/qt-webkit-hardware-acceleration)

### Inferences
- CEF and Electron are Chromium plus more, so they are strictly worse. Chromium also dropped 32-bit ARM Linux desktop builds in mainstream distros long ago (unsourced here). There is no realistic path.

### Gaps
- No official Chromium "minimum RAM" spec found. The 1GB memcheck threshold is the best primary-ish data point.

## Q4. YouTube: in-browser vs. native playback; yt-dlp; decode capability; Cedar

### Takeaway
In-browser YouTube on this device is not viable. QtWebKit 5.212 is unmaintained and NetSurf has no media or modern JS. WPE cannot fit, as covered in Q1. The practical route on weak devices is native: resolve a stream URL off-device or with a light extractor, then play it with ffmpeg/mpv to fb0 and ALSA. Since Nov 2025, yt-dlp needs an external JS runtime (Deno by default) for full YouTube support. Python plus Deno on the device is a poor fit, so URL resolution belongs on the Mac/server, or with a Go extractor like ytgo. Audio-only (m4a/opus) is the easy win. Software decode of 480p H.264 on one A7 is borderline. Cedar hardware decode on V831 has no confirmed ffmpeg integration in sources found.

### Cited Findings
- yt-dlp 2025.11.12 added external JS runtime support. YouTube without a JS runtime is now "deprecated". Deno is enabled by default (Node, QuickJS, QuickJS-ng and Bun are supported but off by default). Without a runtime "available formats may be limited". The yt-dlp-ejs component is bundled in official executables. — [GIGAZINE](https://www.gigazine.net/gsc_news/en/20251113-yt-dlp-required-deno-javascript-runtime); [yt-dlp issue #15012](https://github.com/yt-dlp/yt-dlp/issues/15012)
- Users needed `pipx inject yt-dlp deno` to fix the "no supported runtime" warning (Feb 2026). — [neilzone blog](https://neilzone.co.uk/2026/02/injecting-dependencies-with-pipx/)
- ytgo (Go) claims to use an Innertube client profile that returns direct stream URLs without running JS or deciphering signatures. It has a "get stream URL" call and is ~11MB vs ~17MB for yt-dlp plus CPython. It has far fewer extractors. — [tituscheng/ytgo](https://github.com/tituscheng/ytgo)
- Other options: ytdlp-go (alpha Go port, not drop-in) — [tejasa97/youtube_dlp](https://pkg.go.dev/github.com/tejasa97/youtube_dlp). tydle (Rust) needs a JS runtime for signatures — [tydle](https://docs.rs/crate/tydle/0.1.0/source/README.md). goutubedl and go-yt-dlp are wrappers that still require yt-dlp — [wader/goutubedl](https://github.com/wader/goutubedl)
- Software decode reference points (no direct A7 benchmark found). On a Cortex-A8 (AM335x), 480p H.264 "pegs the CPU at 100%" — [TI E2E](https://e2e.ti.com/support/processors-group/processors/f/processors-forum/273437/am335x-maximum-h-264-decode-capability). TI estimates ~20MHz per 720x480 frame with avdec_h264 on A9, so a theoretical ~50fps at 1GHz with nothing left over — [TI E2E](https://e2e.ti.com/support/arm/sitara_arm/f/791/t/600387). A MIPS 1004K at 700MHz managed ~4→10fps on HD with tuning, with HD needing a hardware decoder — [linux.org.ru](https://www.linux.org.ru/forum/development/11472891)
- Allwinner VE: the vendor cedar_ve/libcedarx stack is described as outdated, and the mainline Cedrus V4L2 driver (Bootlin) is the working path on H3-class chips. mpv/ffmpeg hardware acceleration needs patching. libcedarx forces either encode or decode, not both at once. — [Armbian forum](https://forum.armbian.com/profile/18514-schunckt/content/); [Crowd Supply Cedrus update](https://www.crowdsupply.com/eoma68/micro-desktop/updates/cedrus)
- Whycan (2021, V3s): attempts at ffmpeg plus CedarX (aodzip's tree) for H.264 hit failures. A reply suggests using the OMX libraries or adding a codec to ffmpeg. — [whycan t_6738](https://whycan.com/t_6738.html)

### Inferences
- Python plus Deno on the device: CPython 3 (~15-20MB on disk minimum) plus Deno (a V8-based single binary, ~80-100MB+ on disk, high RSS) does not fit 8.7MB of flash. Running both from tmpfs alongside a player would likely OOM 91.5MB. QuickJS is tiny and supported by yt-dlp, but must be explicitly enabled. Python plus QuickJS in a squashfs is plausible but slow on one A7 (expect tens of seconds per URL resolve). Recommended: resolve on the Mac (yt-dlp `-g -f` for itag 140 m4a or 18 360p mp4) and send the googlevideo URL to the device, or run ytgo as a static armv7 Go binary. Go cross-compiles to linux/arm with GOARM=7, but the ~11MB binary would have to live in tmpfs/squashfs.
- Decode budget. Audio-only AAC/Opus decode on one A7 costs a few percent CPU, so it is very feasible. 360p H.264 (itag 18, single-file progressive mp4 with no DASH muxing needed) is the realistic software-decode target. 480p H.264 is borderline when you add network, the demuxer and the BGRA scale/copy to a 1600x600 fb. YouTube increasingly serves VP9/AV1 for adaptive formats, and those are far heavier than H.264 in software. Pin H.264 (avc1) formats. These are estimates. Benchmark with `ffmpeg -threads 1 -benchmark -i file -f null -`.
- Cedar on V831: the vendor kernel 4.9 has the /dev/cedar_dev (sunxi-cedar) interface. Using it means linking the vendor libcedarc (from the V831 Tina SDK, or MaixPy3/Sipeed's V831 SDK) into a custom player, or using an ffmpeg fork with cedar support. Cedrus/V4L2 needs a mainline kernel, which this device does not run. Feasible but unproven for V831 specifically. The 2D G2D engine could do the YUV→BGRA scale/convert to fb.

### Gaps
- No V831-specific libcedarc + ffmpeg/mpv success report found. Did not search the Sipeed MaixII-Dock (V831) forums or GitHub, where vendor decode demos are most likely.
- No measured Cortex-A7 single-core H.264 fps figures found.
- Invidious/Piped: not researched in this pass. Their public instances have been unstable since YouTube's 2024-2025 anti-bot changes (unsourced here). A self-hosted Invidious on the Mac would just be another off-device URL resolver.
- YouTube MSE compatibility of QtWebKit 5.212 was not directly sourced. QtWebKit 5.212 is a 2019-2020 alpha with no maintained releases, and YouTube's player requires modern JS/MSE. Expect failure.

## Q5. Alternative architecture: render on the Mac, stream frames to the device, forward touches

### Takeaway
This is the proven pattern for dumb displays (Kindle/Kobo/e-ink dashboards, TRMNL), though those projects use periodic PNG snapshots rather than live video. For interactive use, CDP `Page.startScreencast` pushes JPEG frames only when the page repaints, at about 100ms per-frame latency and roughly 7-15fps reported. On the device, a tiny C client (libjpeg-turbo NEON decode → BGRA memcpy into fb0 → FBIOPAN_DISPLAY dirty rect, plus a GT911 evdev → `Input.dispatchMouseEvent`/`dispatchTouchEvent` over a socket) would use a few MB of RAM. This is the recommended architecture for a full web dashboard. It is not a good fit for YouTube video (use native playback for that).

### Cited Findings
- One project replaced 2fps screenshot polling with CDP screencast. Frames arrive at the page's paint rate and drop to zero when idle. Per-frame latency is ~100ms vs 250-500ms per polled screenshot. — [sentinel-stack v3.4.0 release notes](https://github.com/azfarh95/sentinel-stack-public/releases/tag/v3.4.0)
- Screencast frames are base64 JPEG with metadata, and the client must ack each frame (`Page.screencastFrameAck`) or the stream stalls. — [car-browser recorder.rs](https://docs.rs/crate/car-browser/latest/source/src/recorder.rs); [sentri screencast.js](https://rameshbabuprudhvi.github.io/sentri/docs/jsdoc/runner_screencast.js.html)
- Typical tuning: JPEG quality ~50, max 1280x720, `everyNthFrame: 2`, which gave ~15fps at the source and ~7fps net. — [sentri screencast.js](https://rameshbabuprudhvi.github.io/sentri/docs/jsdoc/runner_screencast.js.html). `everyNthFrame` is not an fps guarantee. `maxFramesInFlight` trades latency against throughput. — [macmyths guide](https://macmyths.com/how-to-fix-low-fps-chrome-devtools-protocol-screencasts/)
- PNG encoding and readback dominate Chrome screenshot cost, which is why JPEG screencast is preferred for streaming. — [headless-dev group](https://groups.google.com/a/chromium.org/g/headless-dev/c/aVZw00nzxTU)
- hass-lovelace-kindle-screensaver uses Puppeteer to screenshot a Lovelace view to a PNG served on port 5000, which the Kindle polls. The `?kiosk` URL param hides the nav bar. — [sibbl/hass-lovelace-kindle-screensaver fork](https://github.imc.re/wendevlin/hass-lovelace-kindle-screensaver); [HA community thread](https://community.home-assistant.io/t/home-assistant-dashboard-on-kindle/186110). Related: [sibbl/hass-lovelace-kindle-4](https://github.com/sibbl/hass-lovelace-kindle-4), [jroimartin/hass-shooter](https://beta.pkg.go.dev/github.com/jroimartin/hass-shooter), [web-screenshot-server](https://awesome.ecosyste.ms/projects/github.com%2Fsebersta%2Fweb-screenshot-server)

### Inferences
- The math: one 1600x600 BGRA frame is 3.84MB. A JPEG at q≈60 for a dashboard is roughly 50-150KB, so 10fps is about 0.5-1.5MB/s over WiFi, which is fine. libjpeg-turbo NEON decode of 0.96MP on a 1GHz A7 is plausibly ~20-40ms per frame, so ~10-20fps decode-bound. That is an estimate to benchmark. Send dirty-rect tiles, or set the screencast to exactly 1600x600 (with `deviceScaleFactor 1`) to avoid scaling on the device.
- Lower-latency variant: on the Mac, capture headless Chrome (or a tab) and encode H.264 with ffmpeg (`-tune zerolatency`). The device then needs an H.264 decoder (Cedar). Higher fps, but it depends on the unproven Cedar path. Start with JPEG.
- Touch: map GT911 ABS_MT_POSITION_X/Y to page coordinates and send `Input.dispatchTouchEvent` (or mouse press/release) over a websocket. Puppeteer or Playwright on the Mac handles the CDP side. The device client can be a single static musl C binary under 200KB, which fits easily in the 8.7MB of free flash, so no tmpfs download is needed.
- YouTube via screencast works visually but gives poor video (low fps, JPEG artifacts, no A/V sync, since audio would need to be streamed separately). Treat it as a fallback only.

### Gaps
- Found no existing open-source "CDP screencast → Linux fbdev with touch back-channel" project. Kindle/TRMNL projects are snapshot-based. Similar thin-client tools exist (browser remote-view SDKs), but none targets fbdev.
- No measured libjpeg-turbo decode time on a single A7.

## Q6. Dashboard ecosystems that already target dumb screens

### Takeaway
TRMNL's open BYOS servers (Terminus/byos_hanami in Ruby, LaraPaper in PHP) and the Kindle/Kobo Lovelace screenshot add-ons already produce server-rendered dashboard images for dumb devices. The device just fetches a PNG/BMP on an interval and blits it. That is the cheapest path if refresh every few seconds is enough. It needs a little work to output 1600x600 color instead of e-ink grayscale.

### Cited Findings
- Terminus (usetrmnl/byos_hanami) is TRMNL's reference open-source BYOS server (Ruby/Hanami, Docker), with dashboard, device management, playlists and a JSON API. — [byos_hanami](https://github.com/usetrmnl/byos_hanami); [TRMNL BYOS docs](https://docs.usetrmnl.com/go/diy/byos)
- LaraPaper (Laravel, MIT) generates screens with native plugins including Screenshot and Image Webhook. — [usetrmnl/larapaper](https://github.com/usetrmnl/larapaper)
- A community guide drives a Kobo Clara HD from HA using only TRMNL open-source components plus a Puppeteer screenshot service, and warns that Puppeteer has no auth, so it should not be exposed outside the LAN. — [HA community](https://community.home-assistant.io/t/e-ink-dashboard-on-kobo-clara-hd-using-only-the-open-source-components-of-trmnl/930378)
- The hass-lovelace-kindle-screensaver HA add-on/Docker produces PNGs from Lovelace views. Forks add `REAL_TIME=true` and `COLOR_MODE`. — [HA community](https://community.home-assistant.io/t/home-assistant-dashboard-on-kindle/186110)

### Inferences
- Fast path: run the kindle-screensaver container (or Puppeteer) on the Mac with viewport 1600x600 and color output. The device runs a loop of `wget` → decode PNG/JPEG → write fb0 → pan. Touch can map to fixed hotspot regions posted to a tiny HTTP endpoint on the Mac. The live CDP screencast in Q5 is the upgrade.
- ESPHome displays were not researched. They are an LVGL/MCU-side pattern and not directly reusable on Linux fbdev, although LVGL itself runs fine on fbdev plus evdev (unsourced here).

### Gaps
- Not verified whether TRMNL firmware/API supports non-e-ink color resolutions like 1600x600.

## Prior work on this device family (coordinator follow-up request)

### Takeaway
Searches found no public prior work running a browser or YouTube on V831-based CarPlay screens (Podofo, Lamtto, Carpuride, T86 board, CPAPAAMC) on English sources, and no Chinese-language (whycan) V831 browser/QtWebKit reports. The only related item is a V831 CarPlay dongle root write-up. I could not find the "Hacking Podofo 10.26" EEVblog thread through web search.

### Cited Findings
- A V831-based "Car Play Herilary C-4" dongle was reverse-engineered from Wi-Fi access to root. It is a different product, so the hardware is not confirmed identical. — [Medium via hn.jakechampion.name](https://hn.jakechampion.name/reader/https://medium.com/@louis-e/from-wi-fi-access-to-root-reverse-engineering-a-50-carplay-dongle-a3fbeeeb0be9)
- Searches for "Hacking Podofo" EEVblog only returned the unrelated PoDoFo PDF library CVEs. — [search artefact example: Ubuntu CVE-2023-31567](https://ubuntu.com/security/CVE-2023-31567)
- whycan has V3s (a sibling Allwinner family) CedarX H.264 threads but no V831 browser threads were found. — [whycan t_6738](https://whycan.com/t_6738.html)

### Inferences
- The EEVblog thread is probably only reachable by browsing eevblog.com/forum directly, since search indexing missed it. It should be checked by fetching the forum URL directly.

### Gaps
- Not searched: CSDN or Bilibili for "V831 浏览器" / "V831 硬解", Sipeed MaixII (V831) GitHub/forums for libcedarc decode demos, Lamtto RC13 / Carpuride W903 firmware dumps. These are the highest-value follow-ups for the Cedar decode question.

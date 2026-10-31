# Device-side desktop/video streaming on the Allwinner V831 (decode, display pipeline, transport)

Method note: web sources on V831 video decoding are sparse (Sipeed's docs list only an *encoder*). The most important evidence below comes from **our own stock firmware**. I extracted `/usr/bin/sdvcam` (4.2 MB, dynamically linked against `/lib/ld-musl-armhf.so.1`, eyesee-mpp/cedarc linked in statically) from `build/rootfs_roundtrip.sqsh` with the project's `carplay-sqfs` docker image and ran `strings` on it. The extracted copy is at `<extracted stock rootfs>/usr/bin/sdvcam` and the strings dump is next to it as `sdvcam.str`. Wherever a "source" below is that binary, it is labelled **[local: sdvcam strings]**. Firmware ID string in the binary: `1600x600m35_cpapaamc_v200b`, which is the CPAPAAMC family the coordinator mentioned.

## Q1. Hardware H.264/JPEG decode from userspace (cedarc / eyesee-mpp / cedrus / Sipeed)

### Takeaway
The V831 VE on this board **does do hardware H.264 (and H.265) decode**. The stock CarPlay app decodes the phone's H.264 stream through eyesee-mpp `AW_MPI_VDEC_*` → `AW_MPI_VO_*` with cedarc inside, uses `/dev/cedar_dev` + `/dev/ion`, and rotates through `/dev/g2d`. Public docs only list an encoder, so the decoder is undocumented but proven in shipped code. The lowest-risk route is to reuse the vendor stack, which is already built for musl/armhf. Mainline cedrus/v4l2-request is not an option on the 4.9 vendor kernel.

### Cited Findings
- Sipeed's V831 spec page lists only "Video encoder: H.264, up to 1080p@30fps / H265 up to 1080p@30fps / JPEG up to 1080p@30fps". It lists no decoder and no G2D, and says MIPI DSI is "No support" on the M2 module. — [Sipeed MaixII M2 chip intro](https://wiki.sipeed.com/hardware/en/maixII/M2/introduce.html)
  - Note: our board drives a MIPI panel, so either the Sipeed table is incomplete or it describes their module's pinout. The Sipeed table is not authoritative for this board.
- Sipeed's libmaix maintainers would not provide V831 H.264 encode/decode examples ("codec implementations differ by chip… contact Allwinner"). The issue is closed and the repo archived. The asker also noted that the Tina v83x SDK seemed to cover only the system layer. — [sipeed/libmaix issue #19](https://github.com/sipeed/libmaix/issues/19)
- MaixPy (newer Sipeed products) plays H.264 only as AVC in MP4/FLV and recommends re-encoding with x264 **with B-frames disabled** when decoding fails. That is a useful hint for any Allwinner VE decoder. — [MaixPy 播放视频](https://wiki.sipeed.com/maixpy/doc/zh/video/play.html)
- Stock `sdvcam` contains the full eyesee-mpp VDEC/VO API **[local: sdvcam strings]**:
  - VDEC: `AW_MPI_VDEC_CreateChn`, `AW_MPI_VDEC_SendStream`, `AW_MPI_VDEC_StartRecvStreamEx`, `AW_MPI_VDEC_GetDoubleImage`, `AW_MPI_VDEC_ReleaseDoubleImage`, `AW_MPI_VDEC_SetVEFreq`, `AW_MPI_VDEC_ForceFramePackage`
  - VO: `AW_MPI_VO_Enable`, `AW_MPI_VO_EnableVideoLayer`, `AW_MPI_VO_SetVideoLayerAttr`, `AW_MPI_VO_SendFrame`, `AW_MPI_VO_SetFrameDisplayRegion`, `AW_MPI_VO_SetChnDispBufNum`, `AW_MPI_VO_AddOutsideVideoLayer`
  - System: `AW_MPI_SYS_Init`, `AW_MPI_SYS_Bind`, `AW_MPI_SYS_MmzAlloc`
  - App classes: `EyeseeLinux::H264Player::Vdec::vdecLoop`, `H264Player::MPPVOCallbackWrapper`, and `EyeseeLinux::JpegPlayer`
- cedarc decoder internals are present in the same binary **[local: sdvcam strings]**: `CreateVideoDecoder`, `component/VideoDec_Component.c`, `component/VideoRender_Component.c`, `OMX.CedarX.videoRender`, `H264DecVuiParameters`, many `h265 decode …` error strings, `VideoDecoderSetFreq`, and the error strings `open /dev/cedar_dev fail.` and `vdecoder open /dev/ion failed`. H.265 decode is therefore compiled in as well.
- JPEG/MJPEG decode **[local: sdvcam strings]**: `CreateMjpegPlusDecoder`, `MjpegDecoderDecode`, `lockJpegDecoder`, `JPEG or H264 decoder init begin!`. There is also `register mjpegplus soft decoder failure!!!` and `change nAlignStride … as width of mjpeg decoder just support 16-align`. The word "soft" suggests the MJPEG path may be a software decoder plugin, or have a software fallback, inside cedarc. Whether VE does JPEG decode in hardware on V831 is not confirmed.
- Rotation inside the vendor video path **[local: sdvcam strings]**: `don't use vdeclib to rotate[%d] for vdecFormat[0x%x], we use g2d!`, `fatal error! cedarv rotation[%d] is not support!`, `fatal error! open /dev/g2d failed`, `convert_PIXEL_FORMAT_E_to_g2d_fmt_enh`, `nExtraBufNum = displayHoldNum + rotateHoldNum + smoothNum`, `vdec already rotate [%d] clock-wise`. So the vendor pipeline is VE decode → (G2D rotate 90°) → DE video layer via `hwdisplay.c` (`hwd_layer_request_hlay`, `layer_config`). It does not go through fb0.
- CedarX/cedarc background:
  - linux-sunxi describes CedarX as Allwinner's proprietary framework. It was partly released as "media-codec" (GPL/LGPL), and some codecs remain binary blobs (libvdecoder.so etc.). — [linux-sunxi CedarX](https://linux-sunxi.org/CedarX)
  - There was an LGPL dispute over the blobs. — [allwinner-zh/media-codec-lib issue #2](https://github.com/allwinner-zh/media-codec-lib/issues/2)
  - 2015 announcement of a partial source release (MPEG2/MPEG4/MJPEG/H264). — [linux-sunxi mailing list](https://groups.google.com/g/linux-sunxi/c/IHwrVxjJMUo)
- Mainline alternative: the Cedrus V4L2 stateless driver ([Sunxi-Cedrus wiki](https://linux-sunxi.org/Sunxi-Cedrus)) is a mainline-kernel driver used with FFmpeg's v4l2-request. It does not exist in the Allwinner 4.9 BSP. The VP8 patch discussions are from 2020 mainline ([LKML](https://lkml.iu.edu/hypermail/linux/kernel/2011.3/03693.html)).
- A whycan post on an OpenWrt image for F1C100s/F1C200s/V3s says "加入了全志的libcedarx库,可以通过gstreamer硬解" (added Allwinner libcedarx, hardware decode via GStreamer). That is a different chip family, but it is precedent for community use of the blob on OpenWrt. — [whycan t_7227](https://whycan.com/t_7227.html); related CedarX porting thread [whycan t_7188](https://server7.whycan.com/t_7188.html)

### Inferences
- **Recommended approach (no kernel change):** write a small C program against eyesee-mpp `AW_MPI_VDEC` + `AW_MPI_VO`, linked against the vendor libraries. The VE, ION, G2D and DE-layer plumbing are already proven on this exact kernel by the stock CarPlay app (CarPlay sends H.264 that the head unit must decode at panel resolution).
  - The catch: the MPP libraries are **statically linked into sdvcam**. The rootfs has no separate `libmpp_*.so`/`libvdecoder.so` (only `/usr/lib/eyesee-mpp/libcarplay.so`, `libairplay.so`, audio decoders, etc.).
  - So we need either (a) the matching Tina V83x SDK eyesee-mpp static libs and headers (`mpi_vdec.h`, `mpi_vo.h`, `vdecoder.h`), from Allwinner/whycan/a vendor SDK leak, or (b) to drive sdvcam's own code path. One way to do (b) is to keep sdvcam and feed it a stream the way lylink/CarPlay does; it accepts H.264 from `liblylink*`/`libcarplay.so`.
- If no SDK can be found, the fallback is to call cedar's ioctl interface directly (cedar_dev + ION). That means reimplementing a VE H.264 driver, which is roughly libvdpau-sunxi-level work. Too much effort.
- H.264 stream settings for the VE: Baseline/Constrained-Baseline, no B-frames, Annex-B, ideally 1600x608 or 1600x600 with crop. The decoder works in 16-aligned macroblocks and 600 is not a multiple of 16, so it will output 1600x608 with crop.
- The decoder output is NV12/NV21 (YUV420SP). It can go straight to a DE **video** layer (channel 0/1 supports YUV and scaling). This skips both the fb0 kernel software rotation and any CPU colour conversion.

### Gaps
- No public V831/V833 datasheet text was found confirming decoder max resolution/fps. I infer ≥1080p30 from shared V833/V536-class VE IP: V536 is marketed with 4K30 H.264/H.265 encode/decode ([CNX Lindenis V536](https://www.cnx-software.com/2020/01/21/lindenis-v536-som-sbc-targets-4k-camera-applications/)), but the V831 VE is smaller.
- I did not find a public eyesee-mpp `sample_vdec`/`sample_vo` repo for V831/V833 in this session. The Tina V83x SDK (`tina-v83x`, `eyesee-mpp/middleware/sample/sample_vdec`) is known to exist in vendor SDKs, but I could not cite a public mirror. Next step: search GitHub/gitee for "sample_vdec" + "sun8iw19" or "tina-v83x".
- Unknown whether MJPEG decode on V831 is hardware or the "mjpegplus soft" decoder.
- I found no public prior work hacking the Podofo/CPAPAAMC V831 units for video. The EEVblog "Hacking Podofo 10.26" thread did not show up in searches; results were MacRumors threads and a [Medium write-up rooting a V831 CarPlay dongle](https://hn.jakechampion.name/reader/https://medium.com/@louis-e/from-wi-fi-access-to-root-reverse-engineering-a-50-carplay-dongle-a3fbeeeb0be9), a different product that also uses a V831. A MacRumors poster claims Podofo units are rebranded CheerDriving hardware ([MacRumors p.283](https://forums.macrumors.com/threads/carplay-adapter-to-convert-to-wireless-carplay.2193978/page-283)); this is unverified.

## Q2. Software decode performance on a single Cortex-A7 @ 1 GHz

### Takeaway
libjpeg-turbo NEON gives roughly 20–30 MP/s on Cortex-A7-class cores. A full 1600x600 (0.96 MP) JPEG frame would take about 35–50 ms to decode, i.e. ~15–25 fps of pure decode on one core, before any blit or rotation. Software H.264 at 1600x600 on one A7 is not realistic at 30 fps; expect single digits to low teens. Software JPEG is fine for delta tiles. Full-frame video needs the VE.

### Cited Findings
- On a Raspberry Pi 2 (4x Cortex-A7, single-threaded test), NEON libjpeg-turbo decoded 640x480 JPEGs at 85 images/s, versus 40/s for the OMX hardware path. That works out to ≈26 MP/s (my arithmetic, 0.307 MP × 85). The test was in a Lua loop and the clock was not stated. — [info-beamer: OMX vs CPU JPEG decoding](https://info-beamer.com/blog/omx-jpeg-decoding-performance-vs-libjpeg-turbo)
- Linaro list: one ARM board decoded a 12 MP image in ~1067 ms (~12 MP/s, platform unnamed). libavcodec MJPEG on a 1 GHz OMAP4 (Cortex-A9) reached ~30 MP/s. The ARM SIMD code gives about 2–4x over plain libjpeg for baseline images. — [Linaro-dev thread](https://lists.linaro.org/archives/list/linaro-dev@lists.linaro.org/message/T7YOI7JSGS5Y53FKWI2ZPGGBLNJ5SYWM); [libjpeg-turbo-users](https://groups.google.com/g/libjpeg-turbo-users/c/v_o3A2lxx8s)
- Software H.264: the closest data point is a vendor claim of "up to 30 fps 720p on dual-core Cortex-A9/A15". A single A7 is substantially weaker. — [embedded.com / Ace Thought](https://www.embedded.com/?p=4234517)

### Inferences
- The V831 runs at ~1.0 GHz on a single core and its DDR is weaker than the Pi 2's, so assume the low end: about 20 MP/s → ~45–50 ms per full 1600x600 JPEG frame. Add the kernel software rotation of the fb0 dirty rect (see Q3) and a full-screen JPEG stream on fb0 tops out around **~10–15 fps** with 100% CPU.
- With **delta tiles**, typical desktop changes cover <10% of the screen, so 30 fps is achievable in software. This is the same reason VNC Tight/JPEG works on weak clients.
- Use TurboJPEG's `tjDecompress2` straight into fb0's mmap with `TJPF_BGRA`, chroma 4:2:0, `TJFLAG_FASTDCT`. Decoding to RGB565 is not an option because fb0 is 32bpp.
- openh264/FFmpeg software decode is not worth building. If H.264 is required, use the VE (Q1).

### Gaps
- I found no published tjbench numbers for a single A7 at 1 GHz or for an Allwinner H3/V831. Run `tjbench` on the device (a static musl build is easy) before committing.
- No published FFmpeg h264 single-core A7 fps figure was found.

## Q3. G2D rotation and direct DE layer control (bypassing the fb0 software rotation)

### Takeaway
The vendor 4.9 kernel's fb0 path (`disp_rotation_sw`, NEON) rotates only the dirty rect passed in `var.reserved[0..3]`, so small updates are cheap and only full-frame updates cost ~3.84 MB of CPU copying. To get tear-free full-frame or video output, allocate ION buffers, fill them in **portrait 600x1600** (or rotate with G2D `G2D_CMD_BITBLT_H` + `G2D_ROT_90`), and flip a DE layer with `DISP_LAYER_SET_CONFIG` (0x47) / `DISP_LAYER_SET_CONFIG2` (0x49) on `/dev/disp`. That is exactly what stock sdvcam does (hwdisplay.c + g2d), so it works without kernel changes.

### Cited Findings
- Local kernel source copy `ref/disp_rotation_sw.c` is built under `CONFIG_DISP2_SUNXI_NEON_ROTATION`. It implements `rot_90/270_u8/u16/u32` and buffers through a non-cached vmap (`pgprot_noncached`). The non-cached target makes it slower than a cached memcpy. — [local: <project>/ref/disp_rotation_sw.c]
- Local header `ref/sunxi_display2.h` defines `struct disp_layer_config { struct disp_layer_info info; bool enable; unsigned int channel; unsigned int layer_id; }`, `struct disp_layer_config2` / `disp_fb_info2` (dma_buf `fd`-based buffers), and `DISP_LAYER_SET_CONFIG = 0x47`, `DISP_LAYER_SET_CONFIG2 = 0x49`. — [local: <project>/ref/sunxi_display2.h]
- The stock app drives DE layers directly and uses G2D for rotation **[local: sdvcam strings]**: `hwd_layer_request_hlay`, `hwdisplay.c`, `layer_config`, `set hlay to top`, `hlay:%d, zorder=%d`, `Be careful! DISP_ROTATION SW_SET_ROT is not support now.`, `fatal error! g2d driver[%d] is not valid, can't rotate!`, `EPIXELFORMAT_g2d_format_convert.c`. It also references `/dev/transform` and `DISP_CAPTURE_*`.
- How to use G2D from userspace (sunxi `/dev/g2d`):
  - Fill `struct g2d_blt_h` with `flag_h = G2D_ROT_90`, plus `src_image_h`/`dst_image_h` each holding a dma-buf `fd`, `format` (`G2D_FORMAT_ARGB8888` etc.), width and height, swapping w/h for 90°. Then call `ioctl(fd, G2D_CMD_BITBLT_H, &blt)`.
  - Buffers must be physically contiguous dma-bufs, not malloc memory.
  - Fallback: the old 1.0 interface `G2D_CMD_BITBLT` + `struct g2d_blt`. On some kernels the 2.0 interface returns EPERM or "G2D irq pending flag timeout".
  - Measured on a newer Allwinner part (Radxa Cubie A5E): 1920x1080 ARGB8888 rotate-90 took 8.24 ms (~252 MP/s).
  - Example code: [Ronin-1124/allwinner-g2d-usage-guide](https://github.com/Ronin-1124/allwinner-g2d-usage-guide) (`g2d_rotation_or_mirror.c`); header `sunxi-g2d.h`.
  - — [Radxa G2D usage guide](https://docs.radxa.com/en/cubie/a5e/app-dev/npu-dev/g2d-usage-guide)
- G2D rotation is known to misbehave on some vendor stacks: an NXP i.MX8 Android G2D path drew 90° incorrectly. That is different silicon and only a general caution. — [NXP community](https://community.nxp.com/t5/i-MX-Processors/Android-10-i-MX8MMini-g2d-rotation-issue/m-p/1051938/highlight/true)

### Inferences
- On a 4.9 kernel there is no `/dev/dma_heap`. Allocate with **ION** (`/dev/ion`, `ION_IOC_ALLOC` with the carveout/CMA heap mask, then `ION_IOC_MAP`/`SHARE` to get a dma-buf fd) and pass that fd to G2D (`src_image_h.fd`) and to `disp_fb_info2.fd` in `DISP_LAYER_SET_CONFIG2`. Alternatively, fill `disp_fb_info.addr[]` with physical addresses in the v1 `DISP_LAYER_SET_CONFIG`, which needs a phys-addr ION query (sunxi ION custom ioctl).
  - Header caveat: the 4.9 sun8iw19 `g2d_driver.h` may differ from Radxa's newer `sunxi-g2d.h`. Pull `include/linux/sunxi-g2d.h` / `drivers/char/sunxi_g2d/g2d_driver.h` from a Tina 4.9 tree; the board kernel exposes `allwinner,sunxi-g2d` at `g2d@01480000` (seen in the firmware DTB strings).
- Even if G2D on the V831 is several times slower than the Radxa figure, a 0.96 MP rotate should take a few ms of **hardware** time with no CPU load. That compares favourably with the kernel NEON rotate into uncached memory, which plausibly costs tens of ms per full frame.
- Cheapest full-frame path without G2D: have the Mac send frames **already rotated to 600x1600** and write them into an ION buffer shown on a DE layer, bypassing fb0 entirely. Use two ION buffers and flip with `DISP_LAYER_SET_CONFIG2` for tear-free double buffering. The `ch2/lyr0` layer the kernel uses for fb0 can stay underneath or be disabled.
- For H.264 video: VE NV12 output → G2D rotate (NV12 is supported) → DE video channel 0 layer (YUV, scaler). No CPU colour conversion is needed.
- Risk: fbdev/disp may reclaim the layer on its next pan. Use a different channel/layer than ch2/lyr0 with a higher zorder, as sdvcam's "set hlay to top" suggests.

### Gaps
- I did not find the exact sun8iw19 `g2d_driver.h` online in this session, and no V831-specific G2D throughput figure.
- Whether the 4.9 disp driver on this board accepts `disp_fb_info2` dma-buf fds, as opposed to only physical addresses, needs an on-device test.

## Q4. Framebuffer VNC clients for tiny ARM Linux

### Takeaway
fbvnc (aligrudi; ISC licence; packaged in Alpine for armv7, so a static musl build is trivial) is the standard small option. It sends keyboard/mouse and has a touch-capable fork, but it supports only basic encodings (raw/zlib-class, no Tight-JPEG) and writes straight to fb0. On fb0 it would also have to set the dirty rect in `var.reserved` for the screen to update on this kernel. For a 1600x600 desktop over WiFi, a custom JPEG/delta-tile protocol is likely to beat it.

### Cited Findings
- fbvnc: "a small VNC client for Linux framebuffer"; once connected "it sends keyboard and mouse inputs to the VNC server". — [aligrudi/fbvnc](https://github.com/aligrudi/fbvnc)
- The uklatt fork adds a touch device plus VNC password and ZLIB compression. — [uklatt/fbvnc](https://github.com/uklatt/fbvnc)
- The zohead fork adds VNC auth and mouse fixes and notes the code assumes a 32-bit framebuffer. That matches our BGRA fb0. — [zohead/fbvnc](https://www.github.com/zohead/fbvnc)
- Alpine ships fbvnc for armv7 (ISC licence), so it builds against musl. — [Alpine pkg fbvnc armv7](https://pkgs.alpinelinux.org/package/edge/community/armv7/fbvnc)

### Inferences
- Patch fbvnc so that after each `FramebufferUpdate` rect it calls `FBIOPAN_DISPLAY` with `var.reserved[0..3]` = the rect. Otherwise nothing appears (a verified quirk of this board). Touch from `/dev/input/event4` (GT911, coordinates already 1600x600 landscape) maps 1:1 to VNC pointer events.
- macOS Screen Sharing supports only some encodings and uses Apple-specific auth. Expect to need a third-party VNC server on the Mac or a custom server.
- directvnc (DirectFB-based) is heavier and largely unmaintained. Not recommended at 91 MB free RAM.

### Gaps
- I did not verify fbvnc's exact encoding list (raw/copyrect/hextile/zlib) or its RSS. Read `vnc.c` in the repo. Directvnc details were not researched.

## Q5. Lightweight DIY second-screen protocols and transport bandwidth (WiFi vs USB NCM)

### Takeaway
A custom protocol is the best fit. The Mac sends JPEG-compressed dirty tiles (or pre-rotated tiles) over TCP/WebSocket; the device decodes each tile with libjpeg-turbo into fb0 and pans with the tile rect, or into an ION/DE buffer. Once the stream is compressed, bandwidth is not the bottleneck: ~1–3 Mbit/s for a desktop at 10–30 fps with deltas. USB NCM on USB 2.0 gives the lowest latency and highest headroom, but no published USB2 NCM number was found.

### Cited Findings
- NCM is much more efficient than ECM for gadget networking. Librem 5 iperf3 results: ECM 526 Mbit/s, EEM 761 Mbit/s, NCM 1.67 Gbit/s, but that was on USB 3. The developer chose NCM because it aggregates packets better on USB 2.0's 512-byte bulk packets. — [Purism librem5-base MR 342](https://source.puri.sm/Librem5/librem5-base/-/merge_requests/342)
- NCM on an i.MX6 (USB 2.0) at 100 Mbit/s used ~21.5% CPU, and small packets caused CPU blocking. — [NXP community g_ncm thread](https://community.nxp.com/t5/i-MX-Processors/g-ncm-driver-blocks-CPU-for-small-USB-packets/m-p/521672)
- The project already uses the WiFi (BCM4334 STA, DHCP <board IP>) for an HTTP→fb0 blitter (`device/fbdash.c`). — [local: <project>/README.md]

### Inferences
- Expect USB 2.0 NCM at ~100–250 Mbit/s on this single A7. The CPU, not the bus, will be the limit; use large NTB (`tx_max`) settings. NCM is enabled via configfs `functions/ncm.usb0` and must be bound to the sunxi UDC. Check `/sys/class/udc` and any `otg_role` in `/sys/devices/platform/soc/usbc0/` (sunxi). The Mac side has NCM support built in (CDC-NCM driver in macOS).
- BCM4334 is a 1x1 802.11n chip with a 72/150 Mbit/s PHY. Realistic TCP throughput is roughly 20–40 Mbit/s on 2.4 GHz and a little more on 5 GHz, with jitter. Fine for JPEG deltas, marginal for raw.
- Raw full frames: 1600x600x4 = 3.84 MB → 30 fps = 115 MB/s. That is impossible over either link and would also saturate the CPU. Even RGB565 + RLE needs compression for full-motion content.
- Practical protocol: [u16 x,y,w,h][u32 len][JPEG] tiles of 64x64 or 128x600 strips. The device decodes into fb0 at (x,y) and issues one pan per frame with the union rect. Send video regions as H.264 to the VE (Q1) if the vendor MPP libraries can be obtained.

### Gaps
- No measured USB 2.0 NCM or BCM4334 throughput figures were found in this session. Measure with iperf3 (static musl build) on the device.

## Q6. UVC/DisplayLink-style USB display without UVC/HID gadget (FunctionFS custom)

### Takeaway
It is possible without kernel changes: FunctionFS (present) lets a userspace daemon expose a custom vendor-class interface with bulk endpoints. But macOS has no driver for it, so the Mac side would need a user-space libusb/IOKit client app that captures the screen (ScreenCaptureKit / CGVirtualDisplay) and pushes frames over bulk. NCM is simpler, already a network, and gives similar throughput, so FunctionFS buys little.

### Cited Findings
- (Background only; no direct source found this session for FunctionFS-on-sunxi-4.9 display projects.) The stock rootfs ships `libusb-1.0.so.0` and `setusbconfig` and the CarPlay stack (`liblylinkusb.so`), which shows the vendor already does custom USB protocols. — [local: rootfs listing via unsquashfs -l]

### Inferences
- A FunctionFS vendor interface + a macOS libusb client is how DisplayLink-like DIY projects work. On macOS a user-space libusb client can claim a vendor-class interface with no kext. To appear as a real *extra display*, the Mac app must create a virtual display (private CGVirtualDisplay API) and capture it.
- Recommendation: use NCM + TCP and a custom Mac app (virtual display + capture + JPEG tile encoder). Keep FunctionFS as a later optimisation only if NCM's CPU overhead proves significant.

### Gaps
- No prior-art project for FunctionFS-based USB displays on Allwinner was found in this session. Search terms worth trying: "FunctionFS display gadget", "usb display gadget ffs", "CGVirtualDisplay usb".
- Searches for prior work on the Podofo A3247 / Lamtto RC13 / Carpuride W903 / T86 / CPAPAAMC devices found nothing relevant to video/desktop streaming; the EEVblog "Hacking Podofo 10.26" thread did not surface in web search.

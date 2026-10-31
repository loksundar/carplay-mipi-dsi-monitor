# Music / Audio Player and Network Audio Receiver on the V831 (Cortex-A7, 128MB RAM, musl/Tina)

Scope note: very few sources publish measured RAM (RSS) numbers for these daemons on small ARM boards. Where no number was found, this is said explicitly. Estimates in "Inferences" are the researcher's own and are labelled as such. They need to be confirmed on the device with `cat /proc/<pid>/status | grep VmRSS` during playback.

## 1. Packaging approach: can we reuse OpenWrt prebuilt ipks (arm_cortex-a7_neon-vfpv4, musl)?

### Takeaway
Yes, this is the most practical route. OpenWrt 24.10 publishes prebuilt musl ipks for exactly this ABI, including shairport-sync (3 variants), nqptp, mpd, mpc, mpg123, upmpdcli, alsa-lib/alsa-utils, avahi, ffmpeg, python3-light and yt-dlp. Every ipk is small (tens to hundreds of KB). Flash space (~8.7MB free) is not the binding limit for most of them; RAM is.

### Cited Findings
- The OpenWrt 24.10.0 `arm_cortex-a7_neon-vfpv4` package feed contains these packages: `alsa-lib_1.2.11-r1` (365.1 KB), `alsa-utils_1.2.11-r1` (134.9 KB), `ffmpeg_6.1.4-r1` (111.2 KB, the CLI front-end; the libs are separate), `avahi-nodbus-daemon_0.9_rc5` (22.0 KB), `avahi-dbus-daemon` (39.4 KB) — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)
- The same feed also has `mpd-mini_0.23.15-r2` (370.1 KB), `mpd-full_0.23.15-r2` (423.4 KB), `mpc_0.35-r1` (24.4 KB), `mpg123_1.32.6-r1` (89.1 KB) and `nqptp_1.2.4-r1` (11.9 KB) — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)
- It also has `shairport-sync-mini_4.3.2-r6` (169.6 KB), `shairport-sync-mbedtls_4.3.2-r6` (167.4 KB), `shairport-sync-openssl_4.3.2-r6` (168.3 KB), `python3-light_3.11.16-r1` (2757.9 KB), `upmpdcli_1.8.11-r1` (614.9 KB), `yt-dlp_2025.9.26-r1` (5135.4 KB) — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)
- I did not see snapclient/snapserver, librespot, spotifyd, gmediarender, madplay, libupnp or libsoxr in the sections of the index I read. The page is 685k characters and parts were read only by a summarising tool, so some of these may be present and simply missed — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)
- The OpenWrt packages feed has a snapcast Makefile, and a recent commit fixed snapclient packaging (a missing libsoxr dependency). So snapcast is packaged in OpenWrt, at least on master — [OpenWrt feed snapcast Makefile log](https://git.openwrt.org/feed/packages/atom/sound/snapcast/Makefile?h=master)
- A Freifunk Franken commit says OpenWrt 21.02's own memory use grew enough that 32 MB devices stopped working reliably. This is context for how small OpenWrt userland can be, not a measurement of these packages — [Freifunk Franken](https://git.freifunk-franken.de/freifunk-franken/firmware/pulls/177/commits)

### Inferences
- OpenWrt ipks are `.tar.gz` of `.tar.gz`, so they can be unpacked on the Mac with `tar` and copied to the device. They are dynamically linked against OpenWrt's musl (`/lib/ld-musl-armhf.so.1`) and OpenWrt libs (libubox, libconfig, libmbedtls, etc.). The safest approach is a self-contained prefix or chroot (e.g. `/tmp/owrt` in tmpfs, or on an SD card / NFS from the Mac) holding OpenWrt's own `libc.so` plus deps. Then run with `chroot` or `LD_LIBRARY_PATH` + the OpenWrt loader. This avoids mixing with Tina's older musl. A tmpfs chroot costs RAM equal to its size, so keep it under ~10–15 MB, or mount it from the Mac over NFS/SMB (the busybox kernel 4.9 likely has NFS client support, which needs checking).
- Kernel 4.9 is fine for OpenWrt 24.10 userland in a chroot. Musl does not require a recent kernel for these daemons, though very new syscalls (e.g. `statx`, `time64` variants) may fall back. This is unverified and needs a test.
- Alternatives are Alpine armv7 (musl, `apk` packages, a chroot from minirootfs of ~3 MB compressed) and Buildroot (best for a single static-ish image, but long build). A glibc chroot (Debian armhf) would give raspotify/shairport-sync AirPlay 2 .debs, but its base size (~30–60 MB+ unpacked) would have to live on NFS/SD, not flash or RAM.
- The stock firmware backup's `libasound` + `/usr/share/alsa` config can be reused as the ALSA config source (card names, `asound.conf` routes to ES8388 / QN8027 path). It is worth grepping the backup for `asound.conf`, `qn8027`, `ioctl` strings in vendor binaries.

### Gaps
- I could not confirm from the index whether snapclient, librespot, spotifyd or gmediarender ipks exist for 24.10 arm_cortex-a7_neon-vfpv4 (the index was too long to read fully). Check with `curl -s <index> | grep -E 'snap|libresp|spotif|gmedia'`.
- The musl version shipped by Tina on this device is unknown. It decides whether OpenWrt binaries could run against the system libc directly.

## 2. AirPlay 1/2 receiver (shairport-sync)

### Takeaway
AirPlay 1 (classic) via `shairport-sync-mini` or `-mbedtls` is very feasible on this board: tiny binary, no Avahi needed (tinysvcmdns built in), ALSA backend. Macs and iPhones can still stream to AirPlay 1 receivers. AirPlay 2 is officially recommended for Pi 2 / Pi Zero 2 W class hardware or better (quad-core), needs nqptp, OpenSSL, FFmpeg AAC decoding, libplist/libsodium/libgcrypt and Avahi. It is marginal on a single-core 1 GHz A7 with ~91 MB free: treat it as "possible but risky".

### Cited Findings
- The OpenWrt `shairport-sync-mini` variant uses mbed TLS and does not include libsoxr or avahi. Its installed size is ~97 kB and its deps are small (libconfig, libdaemon, libmbedtls) — [OpenWrt package: shairport-sync-mini](https://openwrt.org/packages/pkgdata/shairport-sync-mini)
- The OpenWrt Makefile builds the mini variant with `--with-ssl=mbedtls --with-tinysvcmdns`. That is the Avahi-free mDNS path — [OpenWrt packages Makefile](https://git.cdn.openwrt.org/feed/packages/tree/sound/shairport-sync/Makefile); [lede-17.01 Makefile](https://git.freifunk-franken.de/mirror/openwrt-packages/src/branch/lede-17.01/sound/shairport-sync/Makefile)
- The OpenWrt 4.3.x Makefile says the mbed TLS version supports only classic AirPlay (AirPlay 1). A forum user reported an mbedtls build showing as "AirPlay2", which conflicts with this — [OpenWrt forum](https://forum.openwrt.org/t/shairport-sync/245277); [OpenWrt Makefile](https://git.cdn.openwrt.org/feed/packages/tree/sound/shairport-sync/Makefile)
- The shairport-sync guidance says the original Raspberry Pi and Pi Zero are powerful enough for AirPlay but "not really suitable for AirPlay 2 operation". AirPlay 2 needs "a slightly more powerful CPU for decoding and synchronisation and more memory for bigger buffers and larger libraries". A Pi 2 / Pi Zero 2 W or better is recommended — [shairport-sync GetTheBest / AIRPLAY2 docs](https://www.github.com/mikebrady/shairport-sync/blob/master/ADVANCED%20TOPICS/GetTheBest.md); [AIRPLAY2.md mirror](https://git.sudo.is/mirrors/shairport-sync/src/branch/master/AIRPLAY2.md)
- AirPlay 2 needs NQPTP, which must have exclusive access to UDP ports 319 and 320. It also needs an FFmpeg AAC decoder that handles float planar (`fltp`) audio. The project says it "does not work well on virtual machines outputting to ALSA" — [AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md)
- A Pi Zero W (single-core ARM11 1 GHz, 512 MB) user reported the original Zero W "struggling" with AirPlay 2 buffered streams. Another user said the Zero 2 W worked fine — [shairport-sync discussion #1229](https://github.com/mikebrady/shairport-sync/discussions/1229); [discussion #1342](https://github.com/mikebrady/shairport-sync/discussions/1342)
- DietPi notes AirPlay 2 adds "slightly" more CPU, "a little more memory" and ~150 MiB extra disk (Debian, with deps) — [DietPi forum](https://dietpi.com/forum/t/req-devel-branch-of-shairport-sync-for-airplay-2/11233)
- `nqptp` for this ABI is 11.9 KB in OpenWrt 24.10, and `shairport-sync-openssl` (the AirPlay 2 capable variant) is 168.3 KB — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)

### Inferences
- **Verdict AirPlay 1: GO.** `shairport-sync-mini` + libmbedtls + libconfig + libpopt/libdaemon + alsa-lib is about 1.5 MB on flash. RSS is likely in the low single-digit MB to ~10 MB range during playback (researcher estimate, not sourced). The audio is ALAC 44.1 kHz, so CPU decode is light. Configure `output_backend = "alsa"; output_device = "hw:2,0"` (ES8388) or a plughw/dmix device. From macOS, AirPlay 1 receivers still appear as targets in Control Center / Music. Multi-room sync with AirPlay 2 speakers is not available for AirPlay 1 targets.
- **Verdict AirPlay 2: MAYBE/RISKY.** The single A7 at 1 GHz is roughly comparable to or a bit better per-clock than the Pi Zero W's ARM11, which upstream says is not suitable. The chain is nqptp + shairport-sync-openssl + avahi-daemon (D-Bus) + libav (AAC) + OpenSSL + libplist/libsodium/libgcrypt. That probably costs 15–30 MB RSS and several MB of flash for ffmpeg libs (researcher estimate). It would need an OpenWrt chroot, as it isn't viable in Tina's userland. Try AirPlay 1 first.
- tinysvcmdns (mini variant) avoids running avahi + dbus, saving several MB RAM.

### Gaps
- No published RSS numbers for shairport-sync (AP1 or AP2) were found. Measure on the device.
- I did not verify whether the OpenWrt 24.10 `shairport-sync-openssl` ipk is actually built with AirPlay 2 enabled.

## 3. Spotify Connect (librespot / raspotify / spotifyd / go-librespot)

### Takeaway
librespot is actively maintained and working as of 2025–2026: v0.7.0 moved to the Dealer and login5 protocols, v0.7.1 followed, and v0.8.0 is the latest. It requires Spotify Premium. A Rust cross-build for `armv7-unknown-linux-musleabihf` with `rustls-tls` and the ALSA backend gives a single binary of a few MB. It is feasible on this board, but librespot has a history of breaking when Spotify changes servers, so plan to update it.

### Cited Findings
- librespot v0.8.0 is the latest release. It adds `SpotifyUri`, local file playback, a fix for connection after suspend, metadata via `get_extended_metadata`, and discovery device aliases — [librespot releases](https://github.com/librespot-org/librespot/releases)
- v0.7.0 replaced the Mercury usage in Spirc with Dealer and added OAuthClient. It added CDN fallback URLs, fixed "TryAnotherAP" rejections, and added a choice of `native-tls` (default) or `rustls-tls`. MSRV is Rust 1.85 (edition 2024) — [librespot releases](https://github.com/librespot-org/librespot/releases)
- In v0.6.0 the HTTP access_token comes from login5, and it added selectable zeroconf backends: Avahi (D-Bus), dns-sd, or the built-in `libmdns`. In v0.5.0 audio moved to the HTTPS CDN and the decoder to Symphonia. v0.4.2 was the "last release on the old API" — [librespot releases](https://github.com/librespot-org/librespot/releases); [librespot CHANGELOG mirror](https://forge.k3s.fr/github-mirrors/librespot/src/branch/dev/CHANGELOG.md)
- In August 2025 a user reported an access point refusing connections, with fallback to other APs and auth via login5 working. The link to Spotify's Ads API sunset was the user's guess — [CoreELEC forum](https://discourse.coreelec.org/t/librespot-addon-suddenly-fails/56096)
- librespot only works with Spotify Premium — [pkgsrc librespot](https://pkgsrc.se/audio/librespot)
- A separate Go implementation, go-librespot, reached 0.7.1 (FreeBSD ports update in May 2026) — [FreeBSD ports bug 295183](https://lists.freebsd.org/archives/freebsd-ports-bugs/2026-May/097136.html)
- spotifyd measured 13 MB RAM (ps_mem, on a desktop rather than an ARM board) — [LinuxLinks spotify-qt memory](https://www.linuxlinks.com/spotify-qt-lightweight-spotify-client/3/)
- Raspotify on an original Pi B+ / first-gen Pi had problems in user reports (no RAM numbers). A moOde user said moving to a Pi Zero 2 W solved load problems. Raspotify writes to temp storage, and a 9-hour track filled tmpfs and crashed it — [raspotify issue #3](https://github.com/dtcooper/raspotify/issues/3); [raspotify discussion #567](https://github.com/dtcooper/raspotify/discussions/567); [moOde forum](https://moodeaudio.org/forum/showthread.php?pid=46017)
- librespot 0.4.1 was built for ARMv7 in some distros and failed on ARMv6 Pi Zero W, so ARMv7 builds are the norm — [moOde forum](https://moodeaudio.org/forum/printthread.php?tid=4924)
- Compressed docker images for librespot linux/arm/v7 are about 6 MB (0.4.2 tag) — [Docker Hub frizzy/librespot-rpi](https://hub.docker.com/r/frizzy/librespot-rpi/tags)

### Inferences
- **Verdict: GO (with Premium).** Build on the Mac with `cross` or `cargo zigbuild`: `cargo build --release --target armv7-unknown-linux-musleabihf --no-default-features --features "alsa-backend,rustls-tls,with-libmdns"`. Statically linking alsa-lib needs a musl alsa-lib built for armv7. Alternatively use the `rodio`/`pipe` backend and pipe raw PCM into `aplay` from OpenWrt's alsa-utils. Run it with `--disable-audio-cache --cache /tmp/ls` (credentials only) and `--bitrate 160` to cut CPU and RAM, plus `--backend alsa --device hw:2,0`. Expected RSS is roughly 10–25 MB (researcher estimate based on the spotifyd 13 MB desktop figure). Vorbis 160 kbps decode on a 1 GHz A7 with NEON should be well under 30% CPU (estimate).
- Spotifyd is built on librespot and brings similar footprint and breakage risk. Raspotify is Debian/glibc .deb only, so it would need a glibc chroot. Prefer plain librespot.
- Avoid `--features avahi` (needs dbus). Use the built-in libmdns zeroconf so the phone app sees the device on LAN without Avahi.

### Gaps
- No measured RSS of librespot on ARMv7 was found.
- Release years are not shown on the releases page. The ordering, the 2026 archive date of a dependent project, and the FreeBSD go-librespot update suggest v0.8.0 is from late 2025.
- I found no 2026-specific report of Spotify breaking librespot beyond the 2025 AP issues.

## 4. UPnP/DLNA renderer, Snapcast client, MPD, internet radio players

### Takeaway
MPD (mini) + mpc, mpg123 and upmpdcli all have OpenWrt ipks for this ABI. mpg123 is the lightest internet-radio player (89 KB ipk). Snapclient runs on OpenWrt routers, including 400 MHz MIPS with the default FLAC codec. gmrender-resurrect depends on GStreamer, which is heavy for 128 MB/16 MB flash. Prefer upmpdcli+mpd-mini for DLNA.

### Cited Findings
- Snapcast: one user ran snapclient on a 400 MHz MIPS router with Ogg Vorbis. The default FLAC codec "runs smoothly on all client devices including OpenWRT routers", but Vorbis encoding choked the router in server mode — [snapcast discussion #1013](https://www.github.com/badaix/snapcast/discussions/1013)
- Two OpenWrt snapclients had continuous dropouts with default settings in another report — [snapcast discussion #1013](https://www.github.com/badaix/snapcast/discussions/1013)
- Snapcast repo — [snapcast/snapcast](https://github.com/snapcast/snapcast) (formerly badaix/snapcast)
- gmrender-resurrect depends on `gstreamer1` and `libupnp` (Buildroot). It calls itself a "resource efficient UPnP/DLNA renderer" — [Buildroot gmrender-resurrect.mk](https://android-kvm.googlesource.com/buildroot/+/c63dc23b87724635b0d90aad1a52b337f5e95d99/package/gmrender-resurrect/gmrender-resurrect.mk); [hzeller/gmrender-resurrect](https://github.com/hzeller/gmrender-resurrect)
- An old (2013) OpenWrt port of gmediarender exists — [JiapengLi/OpenWrt-gmediarender](https://github.com/JiapengLi/OpenWrt-gmediarender)
- The OpenWrt 24.10 ipk sizes are upmpdcli 614.9 KB, mpd-mini 370.1 KB, mpc 24.4 KB, mpg123 89.1 KB — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)

### Inferences
- **mpg123: GO.** It is the simplest internet radio player: `mpg123 -o alsa -a hw:2,0 http://stream.example/radio.mp3` handles MP3 streams and playlists (`-@ url.m3u`). RSS is a few MB (estimate). AAC/HE-AAC streams need ffmpeg or mpd with the faad/ffmpeg plugin.
- **MPD mini + mpc: GO.** Good as the on-device "player engine" for a touchscreen UI (control via TCP 6600). mpd-mini lacks some decoders, and mpd-full adds ffmpeg-based codecs at a higher flash/RAM cost. RSS is likely 5–15 MB depending on buffer settings; set `audio_buffer_size` small (estimate).
- **DLNA: GO via upmpdcli + mpd** (upmpdcli pulls libupnp, libupnpp, libmicrohttpd, jsoncpp, libcurl; total several MB of flash). **gmrender-resurrect: NO-GO/marginal** because GStreamer core + plugins is ~10+ MB flash and significant RAM.
- **Snapclient: GO** if an ipk exists or is cross-built. The Mac can run snapserver (Homebrew `snapcast`) with any audio source, e.g. pipe from yt-dlp/ffmpeg. Use the FLAC or PCM codec (no Opus/Vorbis decode on the client) to keep CPU low, and consider a larger buffer (`--latency`/server buffer) on WiFi.

### Gaps
- No measured RSS for snapclient, mpd, upmpdcli or mpg123 on ARMv7 was found.
- madplay was not found in the 24.10 index sections read. It is largely obsolete; mpg123 covers MP3.

## 5. YouTube / YouTube Music audio

### Takeaway
Run yt-dlp on the Mac, not the device. yt-dlp ipk (5.1 MB) + python3-light (2.8 MB) + deps would consume essentially all 8.7 MB of free flash. Python + yt-dlp extraction also needs tens of MB of RAM, and yt-dlp needs frequent updates because YouTube changes often. Streaming the decoded/re-encoded audio from the Mac to the device is simple and robust.

### Cited Findings
- `yt-dlp_2025.9.26-r1` ipk is 5135.4 KB and `python3-light_3.11.16-r1` ipk is 2757.9 KB for arm_cortex-a7_neon-vfpv4. They would be larger when unpacked — [OpenWrt 24.10.0 package index](https://downloads.openwrt.org/releases/24.10.0/packages/arm_cortex-a7_neon-vfpv4/packages/)

### Inferences (practical recipes; standard yt-dlp/ffmpeg usage, not sourced from a specific page)
- **Option A, HTTP MP3 stream (simplest, device only needs mpg123):** on the Mac, `yt-dlp -f bestaudio -o - "<URL>" | ffmpeg -re -i - -vn -c:a libmp3lame -b:a 192k -f mp3 -listen 1 http://0.0.0.0:8000/live.mp3`. On the device, `mpg123 -o alsa -a hw:2,0 http://<mac-ip>:8000/live.mp3`. For a continuous station, run Icecast on the Mac and push ffmpeg into it, so the device always plays one URL.
- **Option B, raw PCM over TCP/UDP (zero decode on device):** on the Mac, `... | ffmpeg -i - -f s16le -ar 44100 -ac 2 tcp://<device>:5000`. On the device, `nc -l -p 5000 | aplay -D hw:2,0 -f cd`. This costs about 1.4 Mbps on WiFi.
- **Option C, Snapcast:** Mac snapserver with a `pipe:///tmp/snapfifo` source, and yt-dlp|ffmpeg writing s16le to the fifo. The device runs snapclient. This is best if you also want multi-room or a queue.
- **Option D:** Mac AirPlay. Play YouTube Music in a browser on the Mac or iPhone and AirPlay the system audio to shairport-sync (AirPlay 1). The iPhone YouTube Music app can AirPlay directly. This is the lowest-effort path.
- **Verdict on-device yt-dlp: NO-GO** for flash. It is only possible if the rootfs/chroot lives on NFS/SD from the Mac.

### Gaps
- No measured RAM figure for yt-dlp on ARM was found.

## 6. ALSA on sun8iw19 / ES8388: mixer controls to unmute output

### Takeaway
No V831-specific ES8388 asound.conf or amixer recipe was found online. The ES8388 is driven by the ES8328 ASoC driver family. Playback needs the Left/Right Mixer routes (DAC to mixer) enabled, Output 1 (LOUT1/ROUT1, usually headphone) and/or Output 2 (LOUT2/ROUT2) volumes raised, and PCM volume set. The vendor 4.9 driver names may differ, so dump `amixer -c 2 contents` first. Also mine the stock firmware backup's `/usr/share/alsa`/`asound.conf` and startup scripts for the exact `amixer cset` lines.

### Cited Findings
- Mainline `es8328.c` (also used for ES8388) has these controls: `"PCM Volume"`, `"Output 1 Playback Volume"`, `"Output 2 Playback Volume"`, `"Left Mixer Left Bypass Volume"`, and DAPM mixer switches `"Left Playback Switch"`, `"Right Playback Switch"`, `"Left Bypass Switch"`, `"Right Bypass Switch"` on `"Left Mixer"`/`"Right Mixer"`. Its outputs are `LOUT1`, `ROUT1`, `LOUT2`, `ROUT2` via the "Left/Right Out 1/2" PGAs — [Linux mainline es8328.c](https://raw.githubusercontent.com/torvalds/linux/master/sound/soc/codecs/es8328.c)
- A kernel patch fixed the DAC-to-output route by tying playback bits to the mixer widget. Older kernels (like a vendor 4.9) may show different control names, e.g. "Left Mixer Left Playback Switch" — [es8328 route fix patch](https://lkml.rescloud.iu.edu/2502.2/11001.html); [e/OS kernel commit](https://gitlab.e.foundation/e/devices/android_kernel_fairphone_fp5/-/commit/aa91462f1fda9411f5907b08f1063381ed47bb3e)
- An example on another board enables the mixer with `amixer -c 1 sset 'Left Mixer' on`, then raises output volume — [LKML 2021](https://lkml.indiana.edu/hypermail/linux/kernel/2106.3/05283.html)
- On Jetson, setting the ES8388 "Left Playback Switch"/"Right Playback Switch" was the fix for no audio — [NVIDIA forum](https://forums.developer.nvidia.com/t/the-audio-codec-es8388-does-not-work-on-jetson-nano/229432/43)
- On RK3588, ES8388 headphone is routed to LOUT1/ROUT1 (40 mW headphone driver) — [Tencent Cloud article](https://cloud.tencent.com/developer/article/2290305)
- Tina Linux uses standard ALSA. alsa-utils (amixer/aplay) is enabled under Sound in `make menuconfig`. The Allwinner V853 internal codec uses controls like `LINEOUT Output Select`, `LINEOUT Switch`, `LINEOUT volume` on `hw:audiocodec`. That applies to the internal codec (card0 sun8iw19-codec is analogous), not the ES8388 — [100ASK V853 Tina audio tutorial (via search)](https://ewbang.com/community/article/details/1000181009.html)
- A V3s user reported tinyplay "failed to open pcm 0,0" until tinymix routes were set — [whycan t_6029](https://whycan.com/t_6029.html)
- tinyalsa (tinyplay/tinymix) is a tiny alternative to alsa-utils (`-D card -d device`) — [tinyalsa docs](https://docsearch.algolia.com/mcp/docs/repo/tinyalsa/tinyalsa)

### Inferences
- A first-try sequence for card2 (names to be verified with `amixer -c 2 controls`): `amixer -c 2 cset name='Left Mixer Left Playback Switch' on` (or `sset 'Left Mixer' on` / `'Right Playback Switch'` per the driver); the same for the Right Mixer; `amixer -c 2 sset 'Output 1' 80%` (or `'Output 1 Playback Volume'`); `sset 'Output 2' 80%`; `sset 'PCM' 90%`. Then run `speaker-test -D hw:2,0 -c2 -r44100` or `aplay -D hw:2,0 test.wav`.
- ES8388 natively supports 8–96 kHz. Allwinner I2S MCLK constraints often favour 48 kHz-family or 44.1 kHz-family only, depending on the PLL setup. Use `plughw:2,0` or an `asound.conf` `plug` + `dmix` at 48000 or 44100 so shairport (44.1k), librespot (44.1k) and mpd can share the device.
- Without libasound on the base system, tinyalsa's `tinymix`/`tinyplay` (static musl, ~100 KB) are the lightest way to set controls at boot, and they can be used from the init script even when the daemons run in a chroot.

### Gaps
- No V831/V833 Tina ES8388 `asound.conf` or amixer example was found online, and Chinese searches on whycan/CSDN did not surface one. The stock firmware backup is the most reliable source.
- Which ES8388 output (OUT1 vs OUT2) goes to the 3.5mm jack vs the QN8027 input is board-specific and unknown.

## 7. QN8027 FM transmitter: registers, driver interface, audio path

### Takeaway
The QN8027 is an I2C-only control chip (7-bit address 0x2C) with analog audio inputs (ALI/ARI pins). It has no I2S. So the audio reaching it comes from an analog output, most likely an ES8388 LOUT2/ROUT2 or the internal codec LINEOUT, not from a dedicated ALSA card. Setting the frequency is simple: CH = (F_MHz − 76) / 0.05, written to reg 0x00[1:0] (high bits) and 0x01 (low 8 bits). No open-source Linux driver or documentation of the vendor `/dev/qn8027` ioctl interface was found. Reverse-engineer it from the stock firmware binaries, or bypass it by talking to the chip directly via `/dev/i2c-N` (i2c-tools `i2cset`).

### Cited Findings (from the Quintic QN8027 datasheet Rev 1.3, 07/2010)
- It covers 76–108 MHz in 50/100/200 kHz steps, supports RDS/RBDS, and has an I2C interface — [QN8027 datasheet Rev 1.3](https://elektrotanya.com/sites/default/files/comment/2025/05/qn8027_quintic.pdf); [Rev 1.1](https://monitor.espec.ws/download.php?id=165511)
- Pins: ALI (pin 10) and ARI (pin 9) are analog audio inputs. RFO (pin 5) is the RF output to the antenna. SCL/SDA are I2C. It accepts a 12 or 24 MHz crystal or an injected clock — [QN8027 datasheet Rev 1.3](https://elektrotanya.com/sites/default/files/comment/2025/05/qn8027_quintic.pdf)
- I2C slave address is `0101100` (0x2C 7-bit), i.e. 0x58 write / 0x59 read — [QN8027 datasheet Rev 1.3](https://elektrotanya.com/sites/default/files/comment/2025/05/qn8027_quintic.pdf)
- Frequency: "FRF = (76 + 0.05 x Channel Index)" MHz, with a 10-bit CH[9:0] — [QN8027 datasheet Rev 1.3](https://elektrotanya.com/sites/default/files/comment/2025/05/qn8027_quintic.pdf)
- Register map (datasheet): [QN8027 datasheet Rev 1.3](https://elektrotanya.com/sites/default/files/comment/2025/05/qn8027_quintic.pdf)
  - `00h SYSTEM`: bit7 SWRST (reset all regs), bit6 RECAL (reset FSM and recalibrate), bit5 TXREQ (1 = enter transmit, 0 = IDLE), bit4 MONO, bit3 MUTE, bit2 RDSRDY, bits1:0 CH[9:8]
  - `01h CH1`: CH[7:0]
  - `02h GPLT`: bit7 TC pre-emphasis (0 = 50 µs, 1 = 75 µs; default 1. Europe/Asia use 50 µs), bit6 priv_en, bits5:4 t1m_sel. This is the PA-off timer when there is no audio: 00 = 58 s, 01 = 59 s, 10 = 60 s (default), **11 = never**. Bits3:0 GAIN_TXPLT
  - `03h REG_XTL`: bits7:6 XINJ (00 crystal, 01 digital clock on XTAL1, 10/11 sine injection), bits5:0 XISEL crystal current (6.25 µA steps)
  - `04h REG_VGA`: bit7 XSEL (0 = 12 MHz, 1 = 24 MHz; default 1), bits6:4 GVGA input buffer gain, bits3:2 GDB digital gain (0/1/2 dB), bits1:0 RIN input impedance (5/10/20/40 kΩ)
  - `05h/06h CID1/CID2` (read-only chip ID)
  - `07h STATUS`: bits7:4 aud_pk (audio peak × 45 mV), bits2:0 FSM (000 RESET, 001 CALI, 010 IDLE, 011 TX_RSTB, 100 PA cal, 101 Transmit, 110 PA_OFF)
  - `08h–0Fh` RDS data bytes
  - `10h PAC`: bit7 TXPD_CLR, bits6:0 PA_TRGT. Output = 0.62 × PA_TRGT + 71 dBµV, valid 20–75. The new PA setting takes effect only after IDLE→TX or a frequency change
  - `11h FDEV`: TX deviation = 0.58 kHz × TX_FDEV (default 0x81)
  - `12h RDS`: bit7 rdsen, RDSFDEV deviation 0.35 kHz steps
- After power-up the chip enters IDLE automatically. The AGC powers down the transmitter after the silence timeout — [QN8027 datasheet Rev 1.3](https://elektrotanya.com/sites/default/files/comment/2025/05/qn8027_quintic.pdf)
- An Arduino library (dragon-engineer/QN8027) uses I2C address 0x2C, default 88.9 MHz, TX power default 75 (clamped 20–75), and `setCrystal(12MHz)`, `setStereo`, `mute`, `enable(true)` → `begin()` with a reset sequence. Useful as reference code for an init sequence — [dragon-engineer/QN8027](https://github.com/dragon-engineer/QN8027)
- The related QN8066 has a separate Arduino library by Ricardo Lima Caratti. It is a different register layout, so don't mix them up — [Arduino QN8066 library](https://arduino.cc/reference/en/libraries/qn8066)
- Searches for a Linux kernel QN8027 driver or ioctl definition returned nothing relevant — [search results, no hits]; the closest kernel analogue is the Si470x FM *receiver* driver — [radio-si470x-i2c.c](https://lxr.missinglinkelectronics.com/linux+v4.16/drivers/media/radio/si470x/radio-si470x-i2c.c)

### Inferences
- **Userspace direct control (bypasses the unknown /dev/qn8027 ioctl).** If the vendor driver holds the I2C client, use `i2cset -f`, or unload/avoid the driver. Example for 88.9 MHz, CH = (88.9 − 76)/0.05 = 258 = 0x102:
  1. `i2cset -y -f <bus> 0x2c 0x00 0x80` (SWRST)
  2. `i2cset -y -f <bus> 0x2c 0x03 0x10` (crystal; use XINJ = 01 if the board feeds a clock. Check what the stock driver writes)
  3. `i2cset -y -f <bus> 0x2c 0x04 0xB2` (XSEL 24 MHz, default gains) **or** 0x32 for a 12 MHz crystal
  4. `i2cset -y -f <bus> 0x2c 0x00 0x41` (RECAL + CH[9:8] = 01), then `0x00 0x01`
  5. `i2cset -y -f <bus> 0x2c 0x02 0x39` (TC = 50 µs, t1m_sel = 11 never-off, pilot default)
  6. `i2cset -y -f <bus> 0x2c 0x10 0x4B` (PA_TRGT = 75)
  7. `i2cset -y -f <bus> 0x2c 0x01 0x02`, then `0x00 0x21` (TXREQ = 1, CH[9:8] = 01)
  8. Read `i2cget -y -f <bus> 0x2c 0x07` and expect FSM = 101 (Transmit)

  This is derived from the datasheet register descriptions above. The exact init order and crystal setting must be confirmed against the stock driver behaviour.
- **Discovering the vendor interface:** `ls -l /dev/qn8027` (major/minor → `/proc/misc` or `/proc/devices`). Look for the I2C bus and address under `/sys/bus/i2c/devices/*/name`. Run `strings`/Ghidra on the stock firmware app binary from the backup for `open("/dev/qn8027")` and the ioctl numbers (`_IOW('q', n, int)`-style constants), and on the kernel module (`qn8027.ko`, if modular) for its `unlocked_ioctl` switch table. Also try `cat /dev/qn8027` and `echo 889 > /dev/qn8027`, since some Chinese vendor drivers accept text frequency writes. That last idea is speculative.
- **Audio path:** because the QN8027 takes analog ALI/ARI only, the "FM output" is whichever analog output is wired to it. Most likely ES8388 OUT2 (with OUT1 = 3.5 mm jack), or the V831 internal codec LINEOUT/headphone (card0). Test by playing a tone on each card/output while tuned in on an FM radio. The input gain must not clip: use STATUS.aud_pk (×45 mV) to set GVGA/RIN and the ALSA output volume.
- Regulatory: FM transmit power limits apply (e.g. FCC Part 15 in the US). The datasheet says the user must conform to local rules. Keep PA_TRGT modest for an in-car link.

### Gaps
- The vendor `/dev/qn8027` ioctl interface is undocumented in any source found. Reverse-engineering the backup is required.
- Which crystal or clock the board uses for the QN8027 (12 vs 24 MHz, crystal vs injected clock from the SoC) is unknown.
- I found no whycan/CSDN post on V831 + QN8027.

## 8. Prior work on this device family (Podofo / Lamtto / Carpuride / V831 CarPlay screens)

### Takeaway
I found no public project that has added music-receiver software to these V831 CarPlay screens. The most relevant prior work is a 2025 reverse-engineering write-up of a V831-based wireless CarPlay dongle (16 MB SPI NOR, root via Wi-Fi). There is also a 2025 CCC talk on jailbreaking car head units. The EEVblog "Hacking Podofo 10.26" thread did not show up in searches.

### Cited Findings
- A Medium article (author louis-e), "From Wi-Fi Access to Root: Reverse Engineering a $50 CarPlay Dongle" (Herilary C-4), describes an Allwinner V831 SoC, AIC8800 Wi-Fi/BT, and a 16 MB Winbond SPI NOR holding all firmware. Root was obtained via Wi-Fi access. The full text could not be fetched (HTTP 403) — [HN reader mirror](https://hn.jakechampion.name/reader/https://medium.com/@louis-e/from-wi-fi-access-to-root-reverse-engineering-a-50-carplay-dongle-a3fbeeeb0be9)
- CCC (god2025) talk "Pwn my ride – jailbreaking c…" (car infotainment). Its relevance to V831 screens is not verified — [media.ccc.de](https://media.ccc.de/v/god2025-56485-pwn-my-ride-jailbreaking-c/audio)
- On MacRumors, Podofo firmware is updated from an SD card, and users ask whether CheerDriving locks firmware — [MacRumors thread p.277](https://forums.macrumors.com/threads/carplay-adapter-to-convert-to-wireless-carplay.2193978/page-277)
- Retail listings for these screens confirm audio goes to the car "via FM frequency or the included AUX cable", i.e. the QN8027 + 3.5 mm design — [desertcart listing](https://desertcart.sg/zh/products/607272293-bigthree-car-stereo-wireless-apple-carplay-android-auto-portable-7)

### Inferences
- The SD-card firmware update mechanism and the stock `/usr/share/alsa` + app binaries are the best leads for the exact amixer/QN8027 init sequence.

### Gaps
- I did not locate the EEVblog "Hacking Podofo 10.26" thread or any whycan/CSDN/Bilibili posts about Lamtto RC13, Carpuride W903/W904, the T86 board or CPAPAAMC firmware audio. Searches returned only MacRumors and retail pages. A direct forum search on eevblog.com is recommended.

## Summary verdict table (researcher synthesis)

| Feature | Software | Verdict | Est. RSS (unverified) | Flash | Notes |
|---|---|---|---|---|---|
| AirPlay 1 | shairport-sync-mini (mbedTLS, tinysvcmdns, ALSA) | GO | ~3–10 MB | ~1.5 MB w/ deps | Mac/iPhone can target it |
| AirPlay 2 | shairport-sync-openssl + nqptp + avahi + ffmpeg | RISKY | ~15–30 MB | several MB | Upstream says Pi Zero class unsuitable |
| Spotify Connect | librespot v0.8 (Rust, armv7 musl, rustls, libmdns) | GO (Premium) | ~10–25 MB | ~4–8 MB binary | Update often; spotifyd measured 13 MB on desktop |
| DLNA renderer | upmpdcli + mpd-mini | GO | ~10–20 MB | ~3–5 MB | gmrender needs GStreamer, so avoid |
| Snapcast client | snapclient (FLAC/PCM) | GO | few MB | <1 MB + deps | Mac runs snapserver |
| Internet radio | mpg123 (MP3) / mpd | GO | few MB | 89 KB ipk | AAC needs ffmpeg/mpd-full |
| YouTube | yt-dlp on Mac → HTTP/PCM/Snapcast/AirPlay | GO (Mac-side) | — | — | On-device yt-dlp is NO-GO (flash) |
| FM out | QN8027 via i2cset or vendor /dev/qn8027 | GO (with RE) | — | — | Analog input only, fed by an analog codec output |

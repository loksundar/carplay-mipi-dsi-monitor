# Research snapshots

These notes were written **before** the extended display was built, while choosing an approach (2026-10-30).
They are kept for context and are not maintained:
- `REPORT.md`: the summary that led to the chosen design (Mac virtual display + tile streaming).
- `mac_virtual_display.md`, `device_streaming_decode.md`, `touch_input.md`, `web_browser_youtube.md`,
  `music_audio.md`, `fbrowser.md`: the detailed studies behind it.

They mention `fbdash`, the original HTTP→framebuffer dashboard blitter. It has since been removed and replaced by
`vdclient` (display) and `httpc` (command channel). `ref/...` paths point to vendor kernel sources (Allwinner
display driver) that are not included in this repository.

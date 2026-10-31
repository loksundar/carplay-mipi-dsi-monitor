# Wire protocols

## Display protocol (TCP 9100, board dials the Mac)
All integers little-endian. One session per connection; the Mac serves one board at a time.

| Direction | Message | Layout |
|---|---|---|
| board → Mac | hello | `"VD01"` u16 width u16 height (1600, 600) |
| Mac → board | frame | `'F'` u16 nrects, then per rect: u16 x, u16 y, u16 w, u16 h, u8 enc, u32 len, `len` bytes payload |
| board → Mac | ack | `'A'` u16 total_ms u16 decode_ms u16 copy_ms u16 pan_ms (sent after the frame is on screen) |
| board → Mac | touch | `'T'` u8 n, then n × (u16 x, u16 y); n = 0 means all fingers up |

Rect encodings (`enc`):

| enc | Meaning | Payload |
|---|---|---|
| 0 | raw | w*h*4 bytes BGRA rows |
| 1 | JPEG | a JPEG file (decoded with libjpeg-turbo to BGRA) |
| 2 | raw DEFLATE | RFC 1951 stream (no zlib header) of the BGRA rows |
| 3 | copy | u16 src_x, u16 src_y: move the w*h block at (src_x, src_y) to (x, y) — scrolling |

Flow control: the Mac keeps at most 2 frames unacknowledged. On connect the Mac marks the whole screen dirty, so
the first frame is a full repaint. TCP keepalive on both sides (idle 4 s, interval 2 s, count 3); TCP_NODELAY on.

## Command channel (HTTP 8090 on the Mac, board polls)
The board runs `httpc get SERVER 8090 /cmd` every 3 s.
- Empty body → nothing to do.
- Otherwise the body is saved as `/tmp/cmd.sh`, run with `sh` as root, and its combined output is sent with
  `httpc post SERVER 8090 /result`. The Mac appends it to `server/results.log` under a `===== HH:MM:SS` header.
- `/cmd` is served once: the server renames `cmd.sh` to `cmd.sh.sent` immediately.
- Helpers: `GET /files/NAME` (download a file the Mac placed in `server/files/`),
  `POST /upload/NAME` (save the body into `server/uploads/`, e.g. `httpc post ... /upload/fb.raw < /dev/fb0`).

Security: no authentication. Anyone on the LAN who can answer on the Mac's IP:8090 can run commands as root on the
board. Acceptable on a trusted home network only; see EDGE_CASES.md.

## Software FEL trigger
Command: `devmem 0x07000108 0x5aa5a55a; sync; reboot -f`. boot0 enters FEL; `xfel version` then reports V831.

# Operations runbook

Paths are relative to the repository root. `MAC_IP` / `BOARD_IP` are the WiFi addresses from your `config.env`
(the board's own copy of the Mac address is `SERVER` in `/etc/dashboard.conf`). The board reaches WiFi ~13 s after
power-on; the USB link comes up ~10 s later.

## Daily use
- Start: `mac/start.command` from Terminal, or the `CarPlay Monitor.app` launcher made by `mac/make_launchers.sh`
  (add it under System Settings → General → Login Items to start at login). A Terminal window opens and can be closed.
- Stop: `mac/stop.command` (or `Stop CarPlay Monitor.app`). The display disappears; the board shows black.
- The display appears only when the board is connected, and lingers 60 s after it disconnects.
- Arrange the display once in System Settings → Displays; macOS remembers the position. The daemon never moves it.

## Health checks
```sh
tail -3 mac/vdisplay.log            # "device connected from 169.254.100.1" = USB, $BOARD_IP = WiFi; fps stats every 5 s
lsof -tiTCP:8090 -sTCP:LISTEN       # command server running?
pgrep -lf run_vdisplay.sh; pgrep -lx vdisplay
```
On the board (through the command channel): `tail /tmp/dash.log`, `cat /usbnet.log`,
`dmesg | grep -c "G2D irq pending"` (must be 0), `df /overlay`, `grep MemAvailable /proc/meminfo`.

## Running a command on the board (no reflash)
```sh
cd server
echo 'uname -a; df /overlay' > cmd.sh          # picked up within ~3 s
c=$(grep -c '^=====' results.log); until [ $(grep -c '^=====' results.log) -gt $c ]; do sleep 1; done
awk '/^===== /{l=NR} {a[NR]=$0} END{for(i=l;i<=NR;i++)print a[i]}' results.log
```
- The script runs as root with BusyBox sh. Avoid `head`, `grep -A`, `find` (missing).
- Push a file: put it in `server/files/NAME`, then on the board `httpc get $MAC_IP 8090 /files/NAME > /tmp/NAME`.
- Screenshot the board: `httpc post $MAC_IP 8090 /upload/fb.raw < /dev/fb0`, then on the Mac
  `python3 mac/fbshot.py server/uploads/fb.raw shot.png` (needs Pillow: `pip3 install pillow`).
- Never `cp` onto a running binary; never fill the 512 KB overlay (see HARDWARE.md).
- Keep `/usr/bin/httpc` working: the channel itself depends on it.

## Testing a new vdclient without reflashing
`mac/deploy_vdclient.sh` builds `device/vdclient.c` (Docker, staged under $TMPDIR because Docker Desktop
doesn't share every host folder), pushes it, **stops the firmware display loop first** (two processes panning fb0 can wedge
G2D), and runs `/tmp/vdclient` in its own loop until the next reboot.

## Building firmware
```sh
docker build -t carplay-sqfs tools      # once (patched squashfs-tools)
./build.sh                              # → build/rootfs_roundtrip.sqsh, rootfs_dash.sqsh, rootfs_min.sqsh
```
- Input is always your pristine full-flash dump `$BACKUP_IMAGE` (copied read-only into staging; dump it first, see HARDWARE.md).
- `rootfs_roundtrip` = unmodified repack (proves the toolchain), `rootfs_dash` = stock + `overlay/`,
  `rootfs_min` = `rootfs_dash` minus CarPlay etc. (`strip.sh`). **`rootfs_min` is what runs.**
- Board binaries (static armv7, Alpine container):
  - vdclient: see `mac/deploy_vdclient.sh` (`-lturbojpeg -lz`, `-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard`)
  - httpc/devmem/evinject/...: `gcc -static -Os -s -o X X.c`
  - Copy the result into `overlay/usr/bin/` before `./build.sh`.
- Mac daemon:
  ```sh
  cd mac && swiftc -O -swift-version 5 -import-objc-header CGVirtualDisplay.h vdisplay.swift -o vdisplay \
    -framework CoreGraphics -framework ScreenCaptureKit -framework ApplicationServices -framework IOKit
  ```
  Then `./stop.command && ./start.command` (from Terminal). Restarting re-creates the display, so macOS moves its
  windows to the main screen.
- Verify an image before flashing: unsquashfs it in `carplay-sqfs` and compare md5s of the changed files.
  `mksquashfs` embeds timestamps, so whole-image md5s differ between identical builds; compare contents with `diff -r`.

## Flashing (case closed)
```sh
./remote_flash.sh build/rootfs_min.sqsh
```
WiFi command → software FEL → `xfel spinor write 0x2C0000` → read-back compare → `xfel reset` → waits for ping.
Takes ~80 s. Needs: the command server running, the board polling, the USB-C cable to this Mac.
If verify fails the board stays in FEL; rerun, or restore.

Afterwards: check `/overlay/upperdir` holds no stale copies, md5 the installed files, `dmesg | grep G2D`, and watch
`mac/vdisplay.log` for a USB connection.

## Restore / recovery
- Back to stock (CarPlay): get into FEL (software FEL if the command channel works, otherwise open the case and
  short flash CLK→GND at power-on), then `./flash.sh restore`. Writes your full 16 MB factory dump (`$BACKUP_IMAGE`) and verifies.
- Keep your own known-good images: copy each flashed `rootfs_min.sqsh` somewhere safe before building the next one.
- If the board boots but USB setup crashed it: the guard skips USB on the next boot; fix via the command channel.
- If nothing answers: the board's screen shows the boot logo or black. Check WiFi first (router client list), then
  USB (`ifconfig` on the Mac shows an interface with 169.254.100.2).

## Logs
| Log | What |
|---|---|
| `mac/vdisplay.log` | display daemon: connects, display create/remove, 5 s stats |
| `server/dashd.log` | command server requests |
| `server/results.log` | every command's output from the board |
| board `/tmp/dash.log` | boot script + vdclient messages (lost on power-off) |
| board `/usbnet.log` | USB gadget steps (persists) |
| board `/last_boot_fail.log` | written if WiFi never came up within 60 s |

# Guide for AI agents and contributors

Read `README.md`, then `docs/ARCHITECTURE.md` and `docs/OPERATIONS.md`, before changing anything.
`docs/HISTORY.md` lists mistakes that were already made once. Don't repeat them.

## Hard rules
- **Never modify the full-flash backup** (`$BACKUP_IMAGE` in `config.env`). It is the only way back to stock.
  `build.sh` copies it read-only into a staging folder.
- **Never move the macOS display arrangement** programmatically. Users arrange it once in System Settings.
- **Flash safely.**
  - Round-trip first.
  - Verify by reading back. `flash.sh` and `remote_flash.sh` do this.
  - Before a closed-case reflash, make sure the command channel only uses binaries already tested on the board.
    A broken channel means opening the case.
- **The board's writable overlay is only 512 KB.** Never install large files there; build them into the image. If a
  write fails half-way, delete the partial file inside `/overlay/upperdir`, not through `/`, which would create a
  whiteout.
- **Only one process may pan `/dev/fb0`.** Two concurrent `FBIOPAN_DISPLAY` callers can wedge the G2D IRQ until
  reboot. Stop the firmware display loop before testing another client (`mac/deploy_vdclient.sh` does this).
- The Mac daemon must run **under Terminal**, the app holding Screen Recording and Accessibility. A launchd agent
  won't have those permissions.
- **Validate firmware changes with a real power-off.** RTC registers survive warm resets, so some bugs only show on
  cold boots.
- **Never commit secrets.** `config.env` and `overlay/etc/dashboard.conf` (which holds the WiFi password) are git-ignored.
- Board BusyBox lacks `head`, `grep -A`, `find`, `timeout`, `free` and `uptime`. Use `sed`/`awk`.

## Changing things
| What you change | How to test it |
|---|---|
| Mac code | Rebuild with `mac/build.sh`, then `mac/stop.command && mac/start.command`. Restarting moves that display's windows to the main screen. |
| Board display client | `mac/deploy_vdclient.sh` runs a test build from RAM until reboot. Then rebuild the image and use `remote_flash.sh`. |
| Board scripts | Test through the command channel first (`server/cmd.sh` → `server/results.log`). |

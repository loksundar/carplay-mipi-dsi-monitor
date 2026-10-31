# Edge cases, test status and open issues

Status as of 2026-10-31. ✅ = verified, ⚠️ = known gap, ❓ = not yet tested.

## Verified
| Case | Result |
|---|---|
| Finger touch: tap, drag, long-press right-click, two-finger scroll | ✅ (injected events + real finger by the user) |
| USB unplug/drop → WiFi | ✅ ~10 s |
| WiFi → back to USB | ✅ ≤10 s |
| Mac daemon stopped → board black; started → display back | ✅ ≤5 s, same position |
| Board reboot / reflash while Mac running | ✅ display removed after 60 s, re-created on reconnect |
| No board at Mac start | ✅ no display created |
| Link drop mid-drag | ✅ mouse button released (`TouchInput.cancel`) |
| 3-minute soak (scrolling) | ✅ board RSS 8.5–12 MB, Mac memory flat, 0 G2D timeouts |
| Closing the launcher Terminal window | ✅ services keep running |
| Rebuild from new folder | ✅ image contents identical to the flashed one |

## Known gaps / open issues
1. ⚠️ **Mac WiFi IP is not reserved.** The board's `SERVER` (Mac WiFi IP) is baked into `/etc/dashboard.conf`.
   If the router gives the Mac a different address: USB display keeps working (fixed 169.254.100.2), but WiFi
   fallback **and the command channel** stop → no remote updates/reflash without opening the case.
   A DHCP reservation for the Mac avoids it. Planned fix (not done, needs one reflash): command channel tries
   169.254.100.2 first, then SERVER. Optionally the Mac could publish its current WiFi IP over USB.
2. ⚠️ Command channel has no authentication (root shell for anyone answering on the Mac's IP:8090). Fine on a
   trusted home LAN; would need a shared secret/HMAC before any untrusted network.
3. ⚠️ Restarting `vdisplay` (or a >60 s disconnect) removes the display; macOS moves its windows to the main screen
   and does not move them back.
4. ⚠️ Private API (`CGVirtualDisplay`): a macOS update may break it (fix would be Mac-side only).
5. ⚠️ Protected video (Netflix, Apple TV+, DRM in browsers) is expected to show black in capture.
6. ⚠️ The Dock follows the lowest display, so it can move onto this screen (display is arranged below main).
7. ⚠️ Using it as the **only** monitor is not supported: the display exists only after login + daemon start, so login
   window, FileVault unlock, permission prompts and update screens would be invisible.

## Not yet tested
| # | Case | What to look for |
|---|---|---|
| 1 | Real logout/login and full Mac restart | Login Item opens Terminal, permissions still valid, display appears |
| 2 | Display sleep / screen lock / screensaver | Picture resumes on wake; what the lock screen shows; touch on lock screen |
| 3 | Mac system sleep → wake | USB link re-enumerates, reconnect without manual steps |
| 4 | Router reboot / WiFi outage | USB display unaffected; command channel recovers |
| 5 | Overnight / multi-day soak | Mac + board memory flat, no G2D timeouts, board temperature in the closed case |
| 6 | Changing resolution / mirroring in Display Settings | Capture becomes scaled; only reset at next start |
| 7 | 3+ fingers, palm, touching during reconnect | Ignored safely, no stuck buttons |
| 8 | Other cables / USB hubs | Charge-only cables won't enumerate; hubs may reduce speed |
| 9 | macOS update | Daemon still creates the display |
| 10 | Mac IP change (simulate with a different SERVER) | Confirms the impact described in gap 1 |

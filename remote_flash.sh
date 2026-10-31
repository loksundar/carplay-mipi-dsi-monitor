#!/bin/zsh
# Reflash the rootfs with the case closed: WiFi command -> software FEL -> xfel over USB-C -> reset.
#   ./remote_flash.sh build/rootfs_min.sqsh
# Needs: board online (dashd.py running, board polling /cmd) and its USB-C cable connected to this Mac.
# Software FEL: boot0 enters FEL when RTC GPR2 (0x07000108) holds 0x5AA5A55A.
set -e
cd "${0:A:h}"
[[ -f config.env ]] || { echo "copy config.env.example to config.env and fill it in"; exit 1; }
source ./config.env
IMG="$1"
BOARD=$BOARD_IP
[[ -f "$IMG" && "$(head -c 4 "$IMG")" == hsqs ]] || { echo "usage: $0 <rootfs.sqsh>"; exit 1; }
(( $(stat -f %z "$IMG") <= 0xAA0000 )) || { echo "image exceeds rootfs partition"; exit 1; }

if ! $XFEL version >/dev/null 2>&1; then
	echo "Asking board to reboot into FEL..."
	cat > server/cmd.sh <<'CMD'
DEVMEM=/usr/bin/devmem; [ -x $DEVMEM ] || DEVMEM=/tmp/devmem
$DEVMEM 0x07000108 0x5aa5a55a
( sleep 3; sync; reboot -f ) >/dev/null 2>&1 &
CMD
	for i in {1..60}; do $XFEL version >/dev/null 2>&1 && break; sleep 2; done
fi
$XFEL version | grep -q V831 || { echo "board did not enter FEL (USB-C connected to this Mac?)"; rm -f server/cmd.sh; exit 1; }

echo "Writing $IMG at 0x2C0000..."
$XFEL spinor write 0x2C0000 "$IMG" >/dev/null
RB=$(mktemp)
$XFEL spinor read 0x2C0000 $(stat -f %z "$IMG") "$RB" >/dev/null
cmp -s "$IMG" "$RB" || { echo "VERIFY FAILED - board left in FEL; re-run or ./flash.sh restore"; exit 1; }
echo "Verified. Resetting board..."
$XFEL reset >/dev/null 2>&1 || true

for i in {1..60}; do ping -c1 -t2 $BOARD >/dev/null 2>&1 && break; sleep 2; done
ping -c1 -t2 $BOARD >/dev/null 2>&1 && echo "Board back online at $BOARD." || { echo "Board not back on WiFi after 2 min"; exit 1; }

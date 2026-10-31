#!/bin/zsh
# Flash a rootfs image (or restore the full backup) over FEL, then verify by read-back.
#   ./flash.sh build/rootfs_roundtrip.sqsh
#   ./flash.sh build/rootfs_dash.sqsh
#   ./flash.sh restore              # writes the full 16MB backup back to address 0
# Device must already be in FEL (CLK pin6 -> GND pin4 at power-on, short RELEASED).
set -e
cd "${0:A:h}"
[[ -f config.env ]] || { echo "copy config.env.example to config.env and fill it in"; exit 1; }
source ./config.env
ROOTFS_OFF=$((0x2C0000))
ROOTFS_MAX=$((0xAA0000))

if [[ "$1" == restore ]]; then
	IMG=$BACKUP_IMAGE; OFF=0
else
	IMG="$1"; OFF=$ROOTFS_OFF
	[[ -f "$IMG" ]] || { echo "usage: $0 <rootfs.sqsh> | restore"; exit 1; }
	[[ "$(head -c 4 "$IMG")" == hsqs ]] || { echo "$IMG is not a squashfs image"; exit 1; }
	(( $(stat -f %z "$IMG") <= ROOTFS_MAX )) || { echo "$IMG exceeds rootfs partition"; exit 1; }
fi
SIZE=$(stat -f %z "$IMG")

sudo $XFEL version | tee /dev/stderr | grep -q V831 || { echo "no V831 in FEL - re-enter FEL mode"; exit 1; }
sudo $XFEL spinor

printf 'Writing %s (%d bytes) at 0x%X. Continue? [y/N] ' "$IMG" $SIZE $OFF
read -r ok; [[ "$ok" == y ]] || exit 1
time sudo $XFEL spinor write $OFF "$IMG"

echo "Verifying..."
RB=$(mktemp -d)/readback.bin
CHUNK=$((0x100000)); done=0
while (( done < SIZE )); do
	n=$(( SIZE - done < CHUNK ? SIZE - done : CHUNK ))
	sudo $XFEL spinor read $((OFF + done)) $n "$RB.part"
	cat "$RB.part" >> "$RB"; done=$((done + n))
done
if cmp -s "$IMG" "$RB"; then
	echo "VERIFIED OK. Unplug, wait 5s, power on normally."
else
	echo "VERIFY FAILED - do not power-cycle yet; re-run, or ./flash.sh restore"; exit 1
fi

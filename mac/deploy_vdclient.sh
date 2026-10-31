#!/bin/zsh
# Rebuild vdclient, push it to the board's RAM over the command channel and run it
# in place of the firmware copy (until the next reboot).
set -e
cd "${0:A:h}/.."
source ./config.env
cd device
# compile a staging copy under $TMPDIR (Docker Desktop only shares some host folders)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/vdclient.XXXXXX")
cp vdclient.c "$STAGE"/
docker run --rm --platform linux/arm/v7 -v "$STAGE":/src alpine:3.20 sh -c 'apk add -q gcc musl-dev linux-headers libjpeg-turbo-dev libjpeg-turbo-static zlib-dev zlib-static >/dev/null && cd /src && gcc -static -O2 -s -Wall -Wextra -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -o vdclient vdclient.c -lturbojpeg -lz'
cp "$STAGE/vdclient" vdclient && rm -rf "$STAGE"
cp vdclient ../server/files/vdclient
cd ../server
cat > cmd.sh.tmp <<'CMD'
# Stop the firmware's display loop (parent shell of vdclient) so only one
# process ever pans fb0: concurrent FBIOPAN can wedge the G2D irq until reboot.
# The command channel keeps running; a reboot restores the firmware loop.
for p in $(pidof vdclient); do
	grep -qE 'vdclient|/frame' /proc/$p/cmdline 2>/dev/null || continue
	pp=$(cut -d' ' -f4 /proc/$p/stat)
	grep -q dash_start /proc/$pp/cmdline 2>/dev/null && kill $pp
	kill $p
done
sleep 1
/usr/bin/httpc get @MAC_IP@ 8090 /files/vdclient > /tmp/vdclient && chmod 755 /tmp/vdclient
( while :; do /tmp/vdclient 169.254.100.2,@MAC_IP@ 9100 >> /tmp/vd.log 2>&1; sleep 2; done ) > /dev/null 2>&1 &
sleep 3; tail -3 /tmp/vd.log
CMD
sed "s/@MAC_IP@/$MAC_IP/g" cmd.sh.tmp > cmd.sh.new && rm cmd.sh.tmp && mv cmd.sh.new cmd.sh   # board picks up cmd.sh atomically
c=$(grep -c '^=====' results.log); n=0
until [ $(grep -c '^=====' results.log) -gt $c ] || [ $n -ge 60 ]; do sleep 1; n=$((n+1)); done
awk '/^===== /{last=NR} {a[NR]=$0} END{for(i=last;i<=NR;i++)print a[i]}' results.log

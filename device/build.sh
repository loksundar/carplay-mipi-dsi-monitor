#!/bin/sh
# Build the static armv7 board binaries in an Alpine container and copy the ones
# the firmware needs into overlay/usr/bin (run before ../build.sh).
set -e
cd "$(dirname "$0")"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/v831-device.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp ./*.c "$STAGE"/
docker run --rm --platform linux/arm/v7 -v "$STAGE":/src alpine:3.20 sh -ec '
apk add -q gcc musl-dev linux-headers libjpeg-turbo-dev libjpeg-turbo-static zlib-dev zlib-static >/dev/null
cd /src
gcc -static -O2 -s -Wall -Wextra -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -o vdclient vdclient.c -lturbojpeg -lz
for t in httpc devmem evinject i2cscan pantest; do gcc -static -Os -s -Wall -o $t $t.c; done'
for t in vdclient httpc devmem evinject i2cscan pantest; do cp "$STAGE/$t" .; done
cp vdclient httpc devmem ../overlay/usr/bin/
ls -la vdclient httpc devmem evinject i2cscan pantest

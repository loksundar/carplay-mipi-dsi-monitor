#!/bin/sh
# Build rootfs images from the pristine backup:
#   build/rootfs_roundtrip.sqsh  - unmodified repack (flash this first to prove the round-trip)
#   build/rootfs_dash.sqsh       - stock rootfs + overlay/ (extended-display boot hook)
#   build/rootfs_min.sqsh        - rootfs_dash with CarPlay/camera/BT/UI stripped (strip.sh)
# Optional: put a baked-in config at overlay/etc/dashboard.conf before building.
set -e
cd "$(dirname "$0")"
[ -f config.env ] || { echo "copy config.env.example to config.env and fill it in"; exit 1; }
. ./config.env
# Build in a staging copy under $TMPDIR (Docker Desktop only shares some host folders by default).
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/carplay-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R overlay strip.sh "$STAGE"/
mkdir "$STAGE/build"
cp "$BACKUP_IMAGE" "$STAGE/backup.bin"   # read-only copy; the backup itself is never touched
docker run --rm -v "$STAGE":/work -v "$STAGE/backup.bin":/backup.bin:ro carplay-sqfs bash -ec '
MAX=$((0xAA0000))
dd if=/backup.bin of=/tmp/part.bin bs=64k skip=$((0x2C0000/65536)) count=$((MAX/65536)) status=none
unsquashfs -q -n -d /tmp/root /tmp/part.bin
mksquashfs /tmp/root /work/build/rootfs_roundtrip.sqsh -comp xz -b 262144 -noappend -no-progress -quiet
cp -a /work/overlay/. /tmp/root/
chown -R root:root /tmp/root/etc/init.d/S01app /tmp/root/usr/bin/dash_start.sh /tmp/root/usr/bin/httpc /tmp/root/usr/bin/devmem /tmp/root/usr/bin/vdclient /tmp/root/usr/bin/usbnet.sh
[ -f /tmp/root/etc/dashboard.conf ] && chown root:root /tmp/root/etc/dashboard.conf && chmod 600 /tmp/root/etc/dashboard.conf
mksquashfs /tmp/root /work/build/rootfs_dash.sqsh -comp xz -b 262144 -noappend -no-progress -quiet
rm -f /tmp/root/etc/tc_hook
/work/strip.sh /tmp/root
mksquashfs /tmp/root /work/build/rootfs_min.sqsh -comp xz -b 262144 -noappend -no-progress -quiet
for f in rootfs_roundtrip rootfs_dash rootfs_min; do
  s=$(stat -c %s /work/build/$f.sqsh)
  [ $s -le $MAX ] || { echo "$f.sqsh too big: $s > $MAX"; exit 1; }
  unsquashfs -q -n -d /tmp/chk_$f /work/build/$f.sqsh && echo "$f.sqsh: $s bytes (limit $MAX), re-extract OK"
done
ls -la /tmp/chk_rootfs_dash/usr/bin/httpc /tmp/chk_rootfs_dash/usr/bin/vdclient /tmp/chk_rootfs_dash/usr/bin/dash_start.sh
'
mkdir -p build
cp "$STAGE"/build/*.sqsh build/

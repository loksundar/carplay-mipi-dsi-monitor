#!/bin/bash
# Remove CarPlay / Android Auto / camera / Bluetooth / UI from an extracted rootfs ($1).
set -e
R=$1
cd "$R"
rm -f usr/bin/{sdvcam,lylinkapp,lylink.sh,lylink_daemon,mdnsd,btstack_daemon,bluetooth_init.sh,tc_daemon,tca,tc_debug_entry.sh} \
      usr/bin/{ota_update,chroot_ota.sh,copy_system_log.sh,shift_surplus_app_log.sh,monitor-selfboot.sh,udev_handler} \
      usr/bin/{home.png,log_crypto,setusbconfig,getevent,reboot_efex} \
      usr/sbin/{hostapd,udhcpd} etc/hostapd.conf etc/udhcpd.conf etc/dnsmasq.conf
rm -rf usr/lib/eyesee-mpp usr/bin/eyesee-mpp usr/share/alsa usr/share/lua usr/share/osd usr/lib/ts
rm -f etc/init.d/{S00mpp,S00tca,M50usb} etc/udev/rules.d/10-local.rules
# wifi: keep only bcmdhd + the STA firmware
find lib/modules -name '*.ko' ! -name bcmdhd.ko -delete
rm -f lib/firmware/brcm/BCM4334B0.hcd etc/firmware/ap6334/fw_bcm4334b1_ag_{apsta,p2p}.bin etc/firmware/{ap_ctrl.sh,p2p_ctrl.sh}

# drop usr/lib libraries no remaining ELF needs (transitively)
needed() { for f in $(find . -type f -perm -u+x) $(find . -name '*.so*' -type f); do readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'; done | sort -u; }
for pass in 1 2 3; do
	N=$(needed)
	for lib in usr/lib/*.so*; do
		base=$(basename "$lib"); stem=${base%%.so*}.so
		echo "$N" | grep -q "^${stem}" || rm -f "$lib"
	done
done
# every remaining ELF must resolve its libraries
missing=0
for lib in $(needed); do
	[ -e lib/$lib ] || [ -e usr/lib/$lib ] || [ "$lib" = libc.so ] || { echo "MISSING $lib"; missing=1; }
done
exit $missing

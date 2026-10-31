#!/bin/sh
# Expose a USB CDC-NCM network link to the Mac on the USB-C port (device role).
# Board: 169.254.100.1/16; a one-lease DHCP server gives the Mac 169.254.100.2.
UDC=$(ls /sys/class/udc | sed -n 1p)
grep -q configfs /proc/mounts || mount -t configfs none /sys/kernel/config
# this kernel allows a single gadget: reuse whichever one exists
G=$(ls -d /sys/kernel/config/usb_gadget/* 2>/dev/null | sed -n 1p)
[ -n "$G" ] || G=/sys/kernel/config/usb_gadget/v831
if [ ! -e $G/configs/c.1/ncm.usb0 ]; then
	mkdir -p $G && cd $G || exit 1
	echo 0x1d6b > idVendor
	echo 0x0104 > idProduct
	mkdir -p strings/0x409
	echo V831 > strings/0x409/manufacturer
	echo "V831 Display" > strings/0x409/product
	echo 0831 > strings/0x409/serialnumber
	mkdir -p configs/c.1/strings/0x409
	echo NCM > configs/c.1/strings/0x409/configuration
	echo 250 > configs/c.1/MaxPower
	mkdir -p functions/ncm.usb0
	echo 02:08:31:00:00:01 > functions/ncm.usb0/dev_addr
	echo 02:08:31:00:00:02 > functions/ncm.usb0/host_addr
	ln -s functions/ncm.usb0 configs/c.1/
fi
cd $G
# reading usb_device switches the sunxi OTG manager to device role
cat /sys/devices/platform/soc/usbc0/usb_device
sleep 1
[ -n "$(cat UDC)" ] || echo $UDC > UDC
sleep 1
IF=$(cat functions/ncm.usb0/ifname)
ifconfig $IF 169.254.100.1 netmask 255.255.0.0 up
# hand the Mac a fixed address at once (no router/DNS, so it never routes internet here)
cat > /tmp/udhcpd.conf <<CONF
interface $IF
start 169.254.100.2
end 169.254.100.2
max_leases 1
lease_file /tmp/udhcpd.leases
option subnet 255.255.0.0
option lease 86400
CONF
touch /tmp/udhcpd.leases
killall udhcpd 2>/dev/null
busybox udhcpd /tmp/udhcpd.conf
echo "otg_role=$(cat /sys/devices/platform/soc/usbc0/otg_role) udc=$(cat /sys/class/udc/$UDC/state) if=$IF"

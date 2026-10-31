#!/bin/sh
# Join WiFi and bring up the USB link, then act as the Mac's extended display
# (started by /etc/init.d/S01app). The screen is black while no Mac answers.
#
# Config: /etc/dashboard.conf (SSID PSK SERVER PORT).
#
# Remote control without reflashing: polls SERVER /cmd every 3s, runs it as a
# shell script and POSTs the output to /result. Files written on the device land
# in the jffs2 overlay (/overlay/upperdir) and persist across reboots.

LOG=/tmp/dash.log
exec >>$LOG 2>&1
step() { echo "[$(cut -d' ' -f1 /proc/uptime)] $*"; }
step "dash_start"

CONF=/etc/dashboard.conf
if [ ! -f $CONF ]; then
	step "no $CONF, nothing to do"
	exit 1
fi
# provides SSID PSK SERVER PORT
. $CONF
step "ssid $SSID, server $SERVER:${PORT:=8090}"

step "loading wifi driver"
/etc/firmware/sta_ctrl.sh ap6334 load
cat > /var/run/wpa_supplicant/wpa.conf <<WPA
ctrl_interface=/var/run/wpa_supplicant
network={
	ssid="$SSID"
	psk="$PSK"
}
WPA
ifconfig wlan0 up
wpa_supplicant -B -Dnl80211 -iwlan0 -c/var/run/wpa_supplicant/wpa.conf
udhcpc -i wlan0 -b -R
step "wifi up requested"

# keep the log of a boot that never got an address; /tmp is lost on power-off
(
	sleep 60
	ifconfig wlan0 | grep -q 'inet addr' || { cat $LOG; dmesg; } > /last_boot_fail.log
) &

# remote command channel
(
	while :; do
		if /usr/bin/httpc get "$SERVER" "$PORT" /cmd > /tmp/cmd.sh 2>/dev/null && [ -s /tmp/cmd.sh ]; then
			sh /tmp/cmd.sh > /tmp/cmd.out 2>&1
			/usr/bin/httpc post "$SERVER" "$PORT" /result < /tmp/cmd.out
		fi
		sleep 3
	done
) &

# USB-C link to the Mac (CDC-NCM, Mac gets 169.254.100.2), started after the
# command channel so a problem here can still be fixed remotely. If a previous
# attempt never finished (kernel crash -> watchdog reboot), skip it this boot
# so a bad USB setup can't become a reboot loop.
GUARD=/usbnet.inprogress
if [ -e $GUARD ]; then
	rm -f $GUARD
	sync
	step "previous USB setup did not finish, skipping USB this boot"
else
	(
		sleep 10
		touch $GUARD
		sync
		/usr/bin/usbnet.sh
		rm -f $GUARD
		sync
	) &
fi

# Extended display: vdclient dials the Mac's vdisplay daemon (USB first, then
# WiFi) and keeps redialing; restart it if it ever dies.
while :; do
	/usr/bin/vdclient 169.254.100.2,"$SERVER" 9100
	sleep 2
done

#!/bin/zsh
# Keep the vdisplay daemon running (restart if it exits). Must be started from
# Terminal, which holds the Screen Recording and Accessibility permissions.
cd "${0:A:h}"
while true; do
	./vdisplay >> vdisplay.log 2>&1
	echo "[$(date +%T)] vdisplay exited ($?), restarting" >> vdisplay.log
	sleep 2
done

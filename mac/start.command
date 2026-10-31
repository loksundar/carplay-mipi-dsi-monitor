#!/bin/zsh
# Start the V831 screen services on this Mac: the command server and the
# extended-display daemon (auto-restarting). Safe to run twice. Run it from Terminal
# (double-click works), since Terminal holds Screen Recording + Accessibility.
# Also runs at login (Login Item). The display only appears while the screen is
# connected; vdisplay keeps the Mac from idle-sleeping only during that time.
cd "${0:A:h}/.."
if ! lsof -tiTCP:8090 -sTCP:LISTEN >/dev/null; then
	nohup python3 -u server/dashd.py 8090 >> server/dashd.log 2>&1 &
	echo "started command server"
fi
if ! pgrep -f run_vdisplay.sh >/dev/null; then
	nohup mac/run_vdisplay.sh >/dev/null 2>&1 &
	echo "started extended display"
fi
echo "V831 services running. You can close this window."

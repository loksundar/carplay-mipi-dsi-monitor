#!/bin/zsh
# testwin.sh SCRIPT - open a Terminal window titled "vdtest" running SCRIPT, placed on the V831 virtual display
# the V831 display is the one running at 1600x600
id=$(for i in $(seq 1 64); do ${0:A:h}/helpers/modes $i 2>/dev/null | grep -q '^current: 1600x600' && { echo $i; break; }; done)
b=($(${0:A:h}/helpers/modes $id | tail -1 | tr -d '(),' | awk '{print $2, $3}'))
x=${b[1]%.*}; y=${b[2]%.*}
osascript - "$1" $x $y <<'AS' >/dev/null
on run argv
	set x to (item 2 of argv) as integer
	set y to (item 3 of argv) as integer
	tell application "Terminal"
		do script "zsh " & quoted form of (item 1 of argv)
		delay 1
		set custom title of front window to "vdtest"
		set current settings of front window to settings set "Basic"   -- opaque, so scrolling moves pixels
		set bounds of front window to {x + 10, y + 40, x + 1590, y + 590}
	end tell
end run
AS

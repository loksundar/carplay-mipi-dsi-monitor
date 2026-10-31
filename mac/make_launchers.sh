#!/bin/zsh
# Create "CarPlay Monitor.app" and "Stop CarPlay Monitor.app" in a folder (default: this repo's parent).
# The start app opens Terminal running start.command, because Terminal is the app that holds the
# Screen Recording + Accessibility permissions. Add the start app to Login Items to run at login.
set -e
HERE=${0:A:h}
DEST=${1:-${HERE:h:h}}
osacompile -o "$DEST/CarPlay Monitor.app" -e "do shell script \"open -a Terminal \" & quoted form of \"$HERE/start.command\""
osacompile -o "$DEST/Stop CarPlay Monitor.app" -e "do shell script quoted form of \"$HERE/stop.command\"" \
	-e 'display notification "Extended display stopped" with title "CarPlay Monitor"'
echo "created in $DEST"

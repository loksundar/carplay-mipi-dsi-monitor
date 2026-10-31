#!/bin/zsh
# Close test windows opened by testwin.sh without "terminate processes?" sheets:
# stop what runs in them first, then close the finished windows.
pkill -f '/tmp/(flood|longdoc).sh'; pkill -f 'less /tmp/longdoc.txt'
sleep 1
osascript -e 'tell application "Terminal" to close (every window whose custom title is "vdtest")' >/dev/null 2>&1

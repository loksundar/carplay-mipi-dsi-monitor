#!/bin/zsh
# Stop the extended display (the board falls back to the dashboard within ~10 s).
pkill -f run_vdisplay.sh; pkill -x vdisplay
echo "extended display stopped"

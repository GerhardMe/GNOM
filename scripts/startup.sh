#!/usr/bin/env bash

# Log events
exec >>/tmp/startup_debug.log 2>&1
echo "Startup script started at $(date)"

# Select mode
$HOME/GNOMS/scripts/mode-set.sh &

# Start battery monitor
rm /tmp/battery_warning_shown
$HOME/GNOMS/scripts/battery-monitor.sh &
echo "Started battery waring script"

# Cursor hider
unclutter -idle 1 -jitter 2 -root &
echo "Started unclutter"

# Set up screenlock
LOCK="$HOME/GNOMS/scripts/blurlock.sh"
pkill xidlehook || true
xidlehook --not-when-audio --not-when-fullscreen --timer 400 "$LOCK" '' &
xidlehook --not-when-fullscreen --timer 801 "$LOCK" '' &
echo "Started idle screen lock"

# Set upp screen off rule
xset dpms 0 0 900 # Turn off screen after 15min.

# Disable the X bell (water-drop sound on invalid input in GTK apps etc.)
xset -b

# Kill and restart udiskie
pkill udiskie
sleep 0.1 && udiskie &
echo "Started udiskie"

# Restart services so they see environment variables:
systemctl --user restart hw-events.service &
echo "Restarting hw-events service (async)"

# Set the cursor so it's not perpetually loading
xsetroot -cursor_name left_ptr
sleep 0.1
xsetroot -cursor_name left_ptr
sleep 0.1
xsetroot -cursor_name left_ptr
sleep 0.1
xsetroot -cursor_name left_ptr
sleep 0.1
xsetroot -cursor_name left_ptr
echo "Fix cursor loading"

exit 0

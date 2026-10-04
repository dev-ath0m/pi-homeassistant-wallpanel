#!/bin/bash

# Set screen brightness (0-255, lower = dimmer)
echo 30 > /sys/class/backlight/10-0045/brightness

# Rotate screen 180 degrees (DSI display)
xrandr --output DSI-1 --rotate inverted

# Disable screen blanking
xset s off
xset s noblank
xset -dpms

# Hide mouse cursor after a delay
unclutter -idle 0.5 &

# Enable the AT-SPI accessibility bus so Chromium builds its accessibility
# tree and onboard can see text-field focus events to auto-show. This flag
# lives only in the current session bus, so it must be re-set on every login.
dbus-send --session --dest=org.a11y.Bus --type=method_call \
    /org/a11y/bus org.freedesktop.DBus.Properties.Set \
    string:"org.a11y.Status" string:"IsEnabled" variant:boolean:true

# On-screen keyboard, auto-shows on text field focus (configured via dconf:
# auto-show enabled, docked to the bottom edge - see README section 7)
onboard &

# Clear stale Chromium profile locks (can be left behind after an unclean
# shutdown or a hostname change) so kiosk startup never silently fails.
rm -f ~/.config/chromium/Singleton{Lock,Cookie,Socket}

# Wait for Home Assistant to actually be reachable before launching the
# kiosk browser. Auto-login on tty1 (and thus startx/openbox/chromium) has
# no dependency on network-online.target, so on a cold boot/reset it can
# race Wi-Fi association + DHCP by several seconds. Chromium's --kiosk/--app
# mode never auto-retries a failed load, so launching too early leaves the
# panel stuck on a permanent "can't reach this page" error. Give the network
# up to 60s, then launch regardless so the panel isn't blank forever if HA
# is genuinely down.
HA_HOST="192.168.178.11"
HA_PORT="8123"
for i in $(seq 1 60); do
    curl -s -o /dev/null --max-time 2 "http://${HA_HOST}:${HA_PORT}/" && break
    sleep 1
done

# Launch Chromium in kiosk mode
# Replace YOUR_HOME_ASSISTANT_URL with the actual URL of your Lovelace dashboard
# Example: http://homeassistant.local:8123/lovelace/main
chromium --noerrdialogs --disable-infobars --kiosk --force-dark-mode --force-renderer-accessibility --app="http://192.168.178.11:8123/wallpanel-local/0?wp_enabled=true" &

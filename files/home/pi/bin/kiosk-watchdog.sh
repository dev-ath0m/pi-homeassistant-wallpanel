#!/bin/bash
# Kiosk watchdog: detects a hung or missing Chromium kiosk and restarts it.
#
# Chromium's --kiosk/--app mode has no built-in recovery for two failure
# modes seen on this Pi:
#   1. The process disappears entirely (crash, OOM-kill).
#   2. The renderer wedges (JS/GPU deadlock) while the process stays alive
#      and the window keeps showing the last painted frame forever - no
#      crash dump is written, so nothing else notices.
#
# Run periodically via kiosk-watchdog.timer.

set -u
export DISPLAY=:0
export XAUTHORITY="$(ls -t /tmp/serverauth.* 2>/dev/null | head -1)"

CHROMIUM_URL='http://192.168.178.6:8123/wallpanel-local/0?wp_enabled=true'
LOG_TAG="kiosk-watchdog"

relaunch() {
    logger -t "$LOG_TAG" "restarting chromium: $1"
    pkill -9 -f 'chromium.*--app=http' 2>/dev/null
    sleep 2
    rm -f "$HOME/.config/chromium/Singleton"{Lock,Cookie,Socket}
    setsid chromium --noerrdialogs --disable-infobars --force-dark-mode \
        --force-renderer-accessibility --remote-debugging-port=9222 \
        --disk-cache-dir=/tmp/chromium-cache --disk-cache-size=104857600 \
        --remote-debugging-address=127.0.0.1 --app="$CHROMIUM_URL" >/dev/null 2>&1 &
    disown
}

NET_LOG="$HOME/kiosk-network.log"

gateway_up() {
    local gw
    gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
    [[ -n "$gw" ]] && ping -c 2 -W 2 "$gw" >/dev/null 2>&1
}

# Backstop for NetworkManager giving up after repeated failed Wi-Fi
# reconnects (e.g. router down for a while). Escalates: re-activate the
# connection, then restart NetworkManager. Snapshot goes to a disk file since
# the journal is volatile.
if ! gateway_up; then
    {
        echo "=== $(date -Is) gateway unreachable ==="
        nmcli -t -f DEVICE,STATE,CONNECTION dev 2>&1
        journalctl --no-pager --since "-15min" -u NetworkManager -u wpa_supplicant 2>&1 | tail -40
    } >>"$NET_LOG"
    logger -t "$LOG_TAG" "gateway unreachable, reactivating Wi-Fi"
    sudo -n nmcli con up "AS Home Router" >>"$NET_LOG" 2>&1
    sleep 20
    if ! gateway_up; then
        logger -t "$LOG_TAG" "still unreachable, restarting NetworkManager"
        sudo -n systemctl restart NetworkManager >>"$NET_LOG" 2>&1
        sleep 30
    fi
    if gateway_up; then
        echo "=== $(date -Is) recovered ===" >>"$NET_LOG"
    else
        echo "=== $(date -Is) still down after recovery attempts ===" >>"$NET_LOG"
    fi
fi

# onboard (on-screen keyboard) can also get killed/crash independently of
# Chromium; relaunch it too so touch text input keeps working.
if ! pgrep -x onboard >/dev/null; then
    logger -t "$LOG_TAG" "restarting onboard"
    setsid onboard >/dev/null 2>&1 &
    disown
fi

# 1) Process missing entirely (crashed / never started).
if ! pgrep -f 'chromium.*--app=http' >/dev/null; then
    relaunch "no chromium kiosk process found"
    exit 0
fi

# 2) Ask the page for the screensaver boolean (set by HA motion control).
#    off -> the empty dashboard is shown and the screen is meant to be black,
#    nothing to check. A page that doesn't answer at all is a hung renderer.
query_state() { STATE="$("$HOME/bin/kiosk-ha-state.py" 2>/dev/null)"; return $?; }
query_state; RC=$?
if [[ $RC -eq 3 ]]; then
    sleep 20   # may just be busy loading; ask once more before giving up
    query_state; RC=$?
    if [[ $RC -eq 3 ]]; then
        relaunch "page not answering on debug port, assuming hung renderer"
        exit 0
    fi
fi
[[ $RC -ne 0 ]] && STATE=unknown

if [[ "$STATE" == off ]]; then
    logger -t "$LOG_TAG" "screensaver boolean is off (motion control), nothing to check"
    exit 0
fi

# Screensaver on but no photo: WallPanel loads its media list once per page
# load and gives up after 3 retries if the HA websocket drops meanwhile, so
# only the clock shows until the page is reloaded.
if [[ "$STATE" == on-noimage ]]; then
    sleep 30   # image may still be loading right after the screensaver started
    query_state
    if [[ "$STATE" == on-noimage ]]; then
        logger -t "$LOG_TAG" "screensaver on but no image loaded, reloading page"
        "$HOME/bin/kiosk-ha-state.py" --reload >/dev/null 2>&1
        sleep 30
        query_state
        if [[ "$STATE" == on-noimage ]]; then
            relaunch "still no image after page reload"
        fi
        exit 0
    fi
fi

# 3) Boolean is on (or unknown): the slideshow must be moving. Take two
#    screenshots ~65s apart; an identical pair means rendering has stopped.
SHOT1="$(mktemp /tmp/kiosk-watchdog-XXXX.png)"
SHOT2="$(mktemp /tmp/kiosk-watchdog-XXXX.png)"
scrot -o "$SHOT1" >/dev/null 2>&1
sleep 65
scrot -o "$SHOT2" >/dev/null 2>&1

if [[ -s "$SHOT1" && -s "$SHOT2" ]] && cmp -s "$SHOT1" "$SHOT2"; then
    # Without the boolean, a ~2 KB (uniform black) frame can't be told from a screensaver-off screen.
    if [[ "$STATE" == unknown && $(stat -c %s "$SHOT1") -lt 4096 ]]; then
        logger -t "$LOG_TAG" "state unknown and screen uniform, not restarting"
    else
        relaunch "screensaver is $STATE but screen unchanged for 65s, assuming hung renderer"
    fi
fi
rm -f "$SHOT1" "$SHOT2"

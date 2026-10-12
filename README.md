# Home Assistant Kiosk Display Setup (this Pi)

This documents exactly how the attached screen boots straight into a
full-screen Home Assistant (Lovelace/WallPanel) dashboard, so it can be
rebuilt from scratch if the SD card / OS is ever reflashed.

This is **independent of the `espresense-pi` project** — it's general OS
configuration for the console user `pi`, not part of that repo.

## How it boots into the dashboard (chain of events)

1. System boots to `multi-user.target` (text mode, no display manager).
   `nodm` is installed and set as `/etc/X11/default-display-manager`, but it
   is **not actually used** — it only starts under `graphical.target`, which
   this Pi doesn't boot into. It can be ignored/removed.
2. `getty@tty1.service` has a systemd override that auto-logs-in user `pi`
   on tty1 (no password prompt).
3. `pi`'s `~/.bash_profile` detects it's a login shell on `tty1` with no
   `$DISPLAY` set, and runs `startx`.
4. `startx` reads `~/.xinitrc`, which launches `openbox-session` (a
   lightweight X window manager).
5. Openbox runs `~/.config/openbox/autostart` on session start, which:
   - Sets the display backlight brightness.
   - Rotates the screen 180° (this particular panel is mounted upside down).
   - Disables screen blanking / DPMS so the display never sleeps.
   - Runs `unclutter` to hide the mouse cursor when idle.
   - Launches **Chromium in kiosk mode** pointed at the Home Assistant
     dashboard URL.

```mermaid
flowchart TD
    A[Boot: multi-user.target] --> B[getty@tty1 autologin as pi]
    B --> C[.bash_profile runs startx]
    C --> D[.xinitrc runs openbox-session]
    D --> E[openbox autostart script]
    E --> F[Chromium --kiosk -> Home Assistant dashboard]
```

## Required packages

```bash
sudo apt update
sudo apt install -y xserver-xorg xinit x11-xserver-utils openbox \
    chromium unclutter unclutter-startup scrot xdotool xinput \
    onboard gir1.2-atspi-2.0 dconf-cli
```

(`scrot` and `xdotool` are only needed for the [kiosk watchdog](#5-kiosk-watchdog-auto-recovery), `xinput` only for diagnosing/recalibrating touch input, and `onboard`/`gir1.2-atspi-2.0`/`dconf-cli` only for the [on-screen keyboard](#7-on-screen-keyboard-touch-text-input) — none of these are needed for the kiosk itself.)

## 1. Auto-login on tty1

File: `/etc/systemd/system/getty@tty1.service.d/override.conf`

```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
```

To recreate:

```bash
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
EOF
sudo systemctl daemon-reload
sudo systemctl restart getty@tty1.service
```

## 2. Auto-start X on login

File: `~/.bash_profile`

```bash
#!/bin/bash
# Start X on tty1 if not already running
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
```

## 3. X session -> Openbox

File: `~/.xinitrc`

```bash
#!/bin/bash
exec openbox-session
```

Make sure it's executable: `chmod +x ~/.xinitrc`

## 4. Openbox autostart (the actual kiosk launcher)

File: `~/.config/openbox/autostart`

```bash
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
chromium --noerrdialogs --disable-infobars --kiosk --force-dark-mode --force-renderer-accessibility --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 --disk-cache-dir=/tmp/chromium-cache --disk-cache-size=104857600 --app="http://192.168.178.11:8123/wallpanel-local/0?wp_enabled=true" &
```

The debug port is bound to localhost only; the watchdog uses it to read the
screensaver boolean (section 5). Any local process can drive the browser
through it, which is acceptable on this single-user kiosk.

`--disk-cache-dir`/`--disk-cache-size` keep Chromium's HTTP cache in RAM
(`/tmp` is a tmpfs) to spare the boot media; see
[section 8](#8-reducing-writes-to-the-boot-media-usb-stick--sd-card). The
watchdog's `relaunch()` must carry the same flags.

Make sure it's executable: `chmod +x ~/.config/openbox/autostart`

Notes specific to this hardware/setup:

- `/sys/class/backlight/10-0045` is the I2C backlight controller for the
  official Raspberry Pi DSI touchscreen. On a fresh install this path
  should reappear automatically as long as `display_auto_detect=1` is set
  in the boot config (see below) — verify the exact path with
  `ls /sys/class/backlight/` since the I2C bus/address number can differ
  between Pi models.
- `DSI-1` is the xrandr output name for the DSI panel; confirm with
  `DISPLAY=:0 xrandr` if it doesn't match after a fresh install.
- The dashboard URL points at a **WallPanel** view
  (`/wallpanel-local/0?wp_enabled=true`) on a Home Assistant instance at
  `192.168.178.11:8123`. If that IP changes, update the URL here (using
  `homeassistant.local:8123` instead of a raw IP is more resilient to DHCP
  changes).



## 5. Kiosk watchdog (auto-recovery)

Chromium's `--kiosk`/`--app` mode has no built-in recovery for two failure
modes observed on this Pi:

1. The process disappears entirely (crash, OOM-kill).
2. The renderer **wedges** (JS/GPU deadlock) while the process stays alive
   and the window keeps showing the last painted frame forever — no crash
   dump is written, input (mouse/touch) does nothing, and nothing else
   notices. This is what caused the panel to get stuck showing a frozen
   clock/screensaver image for hours until manually restarted.

A watchdog script + systemd timer checks for both every 10 minutes and
restarts Chromium if needed.

File: `~/bin/kiosk-watchdog.sh` (see the file for the full script) — the
key logic:

1. If no `chromium.*--kiosk` process exists, relaunch immediately.
2. Ask the page for `input_boolean.wallpanel_screensaver_local` via
   `~/bin/kiosk-ha-state.py` (a stdlib-only script that evaluates one
   expression over Chromium's localhost debug port, using the page's own HA
   session, so no token is needed).
   - `off`: HA motion control has the screensaver off, so the empty
     dashboard (black screen) is expected. No action.
   - No answer within 10s (checked twice, 20s apart): renderer is wedged,
     relaunch.
3. Boolean `on` (or unknown, e.g. debug port missing): take two screenshots
   ~65s apart (via `scrot`) and compare them byte-for-byte. The slideshow
   always moves, so an identical pair means rendering has stopped — kill and
   relaunch Chromium (clearing the `Singleton*` lock files first, same as the
   normal autostart). If the state is unknown and the frame is uniform
   (PNG under 4 KB), it is not restarted, as it can't be told from
   screensaver-off.

Systemd units:

```bash
sudo tee /etc/systemd/system/kiosk-watchdog.service >/dev/null <<'EOF'
[Unit]
Description=Kiosk watchdog - restart Chromium if hung or crashed
After=graphical.target

[Service]
Type=oneshot
# Without this, systemd kills every process in the unit's cgroup - including
# the detached `setsid chromium ...` the script just launched - the instant
# the script exits, since Type=oneshot units stop as soon as ExecStart
# returns. That silently killed every relaunch attempt, leaving the screen
# blank with just a cursor.
KillMode=process
User=pi
ExecStart=/home/pi/bin/kiosk-watchdog.sh
EOF

sudo tee /etc/systemd/system/kiosk-watchdog.timer >/dev/null <<'EOF'
[Unit]
Description=Run kiosk watchdog periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now kiosk-watchdog.timer
```

Check it ran and what it decided:

```bash
systemctl list-timers kiosk-watchdog.timer
sudo journalctl -u kiosk-watchdog.service -n 20
```

Note a run takes ~65s only when the boolean is on (the screenshot
comparison window); with it off the run finishes immediately. That's
expected, not a hang.

While the boolean is off the black screen is intended, so the watchdog
leaves it alone (see the troubleshooting entry about a black screen with a
healthy Chromium).

## 6. Special settings required for the display to work

Beyond the kiosk scripts above, the following make the physical panel
function at all. Everything here was already present/auto-detected on
this Pi — listed so it can be verified/recreated on a fresh install.

### a. Boot config (`/boot/firmware/config.txt`)

```ini
# Automatically load overlays for detected DSI displays
display_auto_detect=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
disable_overscan=1
```

- `display_auto_detect=1` + `dtoverlay=vc4-kms-v3d` are what let the
  firmware detect the DSI panel and load the correct overlay automatically
  — without these there is no display output at all.
- These are Raspberry Pi OS Bookworm+ defaults; you normally don't need to
  add them by hand on a fresh flash, but verify they're present (not
  commented out) if the screen stays blank.
- No `dtparam=i2c_arm=on` is needed — the panel's backlight/touch chips sit
  on the DSI connector's own dedicated I2C bus, which the display overlay
  enables itself.

### b. Panel hardware (auto-detected, no config file needed)

Confirmed via `dmesg` / `/proc/bus/input/devices`:

- Backlight controller at `/sys/class/backlight/10-0045/brightness`
  (I2C address `0x45`).
- Capacitive touch controller `ft5x06` at I2C address `0x38`, exposed as a
  normal evdev input device — no extra driver install required.

If these paths differ after a reinstall (different Pi model/panel), update
the path in `~/.config/openbox/autostart` and re-check with
`ls /sys/class/backlight/` and `cat /proc/bus/input/devices`.

### c. Backlight write permission (udev rule)

File: `/etc/udev/rules.d/backlight.rules`

```
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
```

Without this rule the brightness sysfs file is root-owned and the
`echo 30 > .../brightness` line in `openbox/autostart` (which runs as user
`pi`, not root) fails silently with a permission error. This also requires
`pi` to be a member of the `video` group:

```bash
sudo usermod -aG video pi
```

(log out/reboot for the group change to take effect).

### d. Touch rotation calibration

The panel is rotated 180° via `xrandr --output DSI-1 --rotate inverted` in
the kiosk script. libinput does **not** auto-sync touch coordinates to a
rotated output — the `ft5x06` touch device reports raw (unrotated)
coordinates, so without an explicit transform, touch ends up mirrored 180°
from what's shown on screen (e.g. tapping the top-left corner hits the
bottom-right). Confirm with `DISPLAY=:0 xinput list-props "10-0038 generic
ft5x06 (79)"` — a `Coordinate Transformation Matrix` of the identity
(`1 0 0 0 1 0 0 0 1`) means no transform is applied yet.

File: `/etc/X11/xorg.conf.d/40-touch-rotate.conf`

```
Section "InputClass"
    Identifier "touch-rotate"
    MatchProduct "generic ft5x06"
    Option "TransformationMatrix" "-1 0 1 0 -1 1 0 0 1"
    Driver "libinput"
EndSection
```

The matrix above is a 180° rotation; adjust for a different orientation.
This file only takes effect on the next X server start (device add time),
not instantly. To apply it to the **current** session without restarting X
(and without kicking the kiosk), set it live with `xinput` instead:

```bash
DISPLAY=:0 XAUTHORITY=$(ls -t /tmp/serverauth.* | head -1) \
    xinput set-prop "10-0038 generic ft5x06 (79)" \
    "Coordinate Transformation Matrix" -1 0 1 0 -1 1 0 0 1
```

Do both: the `xinput set-prop` fixes the running session immediately, the
`xorg.conf.d` file makes it survive the next reboot/X restart. The exact
device name/path (`10-0038 generic ft5x06 (79)`) can shift on a fresh
install — check with `DISPLAY=:0 xinput list`.

## 7. On-screen keyboard (touch text input)

Chromium has no built-in on-screen keyboard on Linux/X11 (that's a
ChromeOS/Android-only feature), so tapping a text field in the dashboard
did nothing. Fixed with **onboard**, auto-shown via the **AT-SPI**
accessibility bus whenever a text field gets focus.

Three pieces have to line up for auto-show to work:

1. **AT-SPI accessibility must be turned on for the session.** This is a
   session-bus flag (`org.a11y.Status.IsEnabled`) that desktop environments
   normally flip via their settings daemon — openbox has no such daemon, so
   it's set by hand on every login:

   ```bash
   dbus-send --session --dest=org.a11y.Bus --type=method_call \
       /org/a11y/bus org.freedesktop.DBus.Properties.Set \
       string:"org.a11y.Status" string:"IsEnabled" variant:boolean:true
   ```

   Without this, Chromium never loads its ATK/AT-SPI bridge, so onboard
   never sees focus events no matter how it's configured — this was the
   actual reason the keyboard never appeared.
2. **Chromium must build its accessibility tree.** Forced unconditionally
   with the `--force-renderer-accessibility` flag on the `chromium` command
   line (otherwise it only builds the tree lazily, after something has
   already queried it — a chicken-and-egg problem that can require two
   focus attempts before onboard notices).
3. **onboard itself**, launched in the background with auto-show enabled.
   Requires the `gir1.2-atspi-2.0` typelib package — without it onboard
   logs `Atspi typelib missing, auto-show unavailable` and silently never
   pops up even with everything else correct.

onboard's auto-show/docking behavior is stored in `dconf`
(`~/.config/dconf/user`), set once and persisted on disk:

```bash
dconf write /org/onboard/auto-show/enabled true
dconf write /org/onboard/layout "'Phone'"
dconf write /org/onboard/window/docking-enabled true
dconf write /org/onboard/window/docking-edge "'bottom'"
```

Both the `dbus-send` call and `onboard &` are added to
`~/.config/openbox/autostart` (before the Chromium launch line), and
`chromium`'s launch line gets `--force-renderer-accessibility` added. The
[watchdog](#5-kiosk-watchdog-auto-recovery)'s `relaunch()` also carries the
same Chromium flag and separately restarts `onboard` if it isn't running,
since a watchdog-triggered Chromium relaunch doesn't re-run the rest of
`autostart`.

Verify it works: focus any text field on the dashboard (or test in
isolation with `chromium --force-renderer-accessibility --user-data-dir=/tmp/t
"file:///path/to/page/with/an/input.html"`, using a scratch
`--user-data-dir` so it doesn't just forward the URL to the already-running
kiosk instance via the Chromium single-instance lock) — onboard should pop
up docked at the bottom within a second or two of the tap/click.

## 8. Reducing writes to the boot media (USB stick / SD card)

The OS runs from a USB stick, which wears out with constant small writes.
The measures below move the heaviest writers to RAM. Already RAM-backed on
this Pi (Raspberry Pi OS Trixie defaults): `/tmp` (tmpfs) and swap (zram), so
nothing to do there. Verify with `mount | grep /tmp` and `swapon --show`.

### a. Journal in RAM

File: `/etc/systemd/journald.conf.d/volatile.conf`

```ini
[Journal]
Storage=volatile
RuntimeMaxUse=64M
```

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/volatile.conf >/dev/null <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF
sudo systemctl restart systemd-journald
sudo rm -rf /var/log/journal   # drop the old persistent journal
```

Trade-off: `journalctl` history (including the watchdog's `logger` messages)
is lost on every reboot, so a crash that caused a reboot leaves no log.
Temporarily switch back to `Storage=persistent` when debugging boot problems.

### b. Less frequent ext4 journal commits

In `/etc/fstab`, add `commit=60` to the root mount options (default is 5 s):

```
PARTUUID=xxxxxxxx-02  /  ext4  defaults,noatime,commit=60  0  1
```

```bash
sudo findmnt --verify          # must report 0 errors before rebooting
sudo systemctl daemon-reload
sudo mount -o remount /
```

Trade-off: a power cut can lose up to ~60 s of writes (the filesystem itself
stays consistent).

### c. Chromium cache in RAM

Chromium's cache was the largest writer (~800 MB under `~/.cache/chromium`).
The `--disk-cache-dir=/tmp/chromium-cache --disk-cache-size=104857600` flags
(already in the autostart and watchdog launch lines) keep it in RAM, capped at
100 MB. The profile in `~/.config/chromium` stays on disk on purpose, since it
holds the Home Assistant login; clear any old on-disk cache once with
`rm -rf ~/.cache/chromium/Default/Cache ~/.cache/chromium/Default/Code\ Cache`.

### c2. zram swap without a backing file

Raspberry Pi OS defaults to `zram+file`, where zram writes idle pages back to
`/var/swap` (2 GB on the stick). With 4 GB RAM and this workload swap use is
tiny, so use plain zram (takes effect after a reboot; check `swapon --show`):

```bash
sudo mkdir -p /etc/rpi/swap.conf.d
printf '[Main]\nMechanism=zram\n' | sudo tee /etc/rpi/swap.conf.d/90-zram-only.conf
```

### d. Unneeded timers and apt cache files

```bash
sudo systemctl disable --now man-db.timer   # rebuilds the man page index

# apt rewrites two ~70 MB binary cache files on every update
printf 'Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\n' | sudo tee /etc/apt/apt.conf.d/02nocache
sudo rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
```

### Checking the result

Per-process write totals since boot (run after the kiosk has been up a while):

```bash
for p in /proc/[0-9]*; do w=$(sudo awk '/^write_bytes/{print $2}' $p/io 2>/dev/null); \
  [ -n "$w" ] && [ "$w" -gt 0 ] && echo "$w $(cat $p/comm)"; done | sort -rn | head
```

## 9. Power button and cooling fan (GPIO)

Both are configured in `/boot/firmware/config.txt`:

```ini
dtoverlay=gpio-shutdown
[all]
dtoverlay=gpio-fan,gpiopin=14,temp=60000
```

### a. Shutdown button on GPIO3 (pin 5)

- `gpio-shutdown` defaults to GPIO3, active-low with internal pull-up. Wire a
  momentary switch between GPIO3 (pin 5) and ground (pin 6 or 9); no external
  resistor.
- The overlay registers an input device (`soc:shutdown_button@3`, `KEY_POWER`)
  and `systemd-logind` handles it with `HandlePowerKey=poweroff`, so a press
  gives a clean shutdown.
- Pressing the same button while halted wakes the Pi 4, which needs
  `WAKE_ON_GPIO=1` in the bootloader EEPROM (the default).
- GPIO3 is also I2C1 SCL; this works only while `dtparam=i2c_arm` stays off.
- Test: `sudo apt install evtest && sudo evtest /dev/input/event0` and press
  the button (expect `KEY_POWER` press/release).

### b. Fan on GPIO14 (pin 8)

- The kernel `gpio-fan` driver switches the pin on above 60 °C
  (`temp=60000`). `pinctrl get 14` should show an output while Linux runs.
- GPIO14 is also the UART TX pin. With `BOOT_UART=1` in the bootloader
  EEPROM, the firmware drives GPIO14 as UART while halted and during early
  boot, and the idle-high TX line kept the fan running after shutdown. Fix:

  ```bash
  sudo rpi-eeprom-config > /tmp/boot.conf
  sed -i 's/^BOOT_UART=1/BOOT_UART=0/' /tmp/boot.conf
  sudo rpi-eeprom-config --apply /tmp/boot.conf
  sudo reboot
  ```

  Verify with `sudo rpi-eeprom-config | grep UART` (expect `BOOT_UART=0`),
  then `sudo poweroff` and check the fan stops.
- Do not use `POWER_OFF_ON_HALT=1` to stop the fan: it needs
  `WAKE_ON_GPIO=0`, which disables the button wake above.
- If the fan still runs after halt, add a ~10 kΩ pull-down from GPIO14 to
  ground, or move the fan to a non-UART pin and change `gpiopin=`.

## Rebuilding from a blank SD card — step by step

1. Flash Raspberry Pi OS, enable SSH, set username `pi`, boot it.
2. Install packages (see [Required packages](#required-packages)).
3. Confirm the boot config lines in [section 6a](#a-boot-config-bootfirmwareconfigtxt)
   are in `/boot/firmware/config.txt` (add if missing), reboot if changed.
4. Confirm `pi` is in the `video` group and the backlight udev rule
   ([section 6c](#c-backlight-write-permission-udev-rule)) exists — needed
   for the brightness line in the kiosk script to work without root.
5. Create the getty autologin override (step 1) and reload systemd.
6. Create `~/.bash_profile` (step 2).
7. Create `~/.xinitrc` and `chmod +x` it (step 3).
8. Create `~/.config/openbox/autostart`, `chmod +x` it, and edit the
   Chromium `--app=` URL to point at your Home Assistant dashboard (step 4).
9. Create `~/bin/kiosk-watchdog.sh` and the `kiosk-watchdog.service`/`.timer`
   units (step 5) so a hung or crashed Chromium recovers on its own.
10. Check the backlight path (`ls /sys/class/backlight/`) and xrandr output
   name (`DISPLAY=:0 xrandr`) match what's used in the autostart script;
   adjust if different. Also verify touch works correctly after the 180°
   rotation ([section 6d](#d-touch-rotation--no-manual-calibration-configured)).
11. Set the onboard dconf keys and verify the on-screen keyboard pops up on
    text field focus ([section 7](#7-on-screen-keyboard-touch-text-input)).
12. If booting from a USB stick / SD card you want to preserve, apply the
    write-reduction settings ([section 8](#8-reducing-writes-to-the-boot-media-usb-stick--sd-card)).
13. Add the power button and fan overlays and set `BOOT_UART=0`
    ([section 9](#9-power-button-and-cooling-fan-gpio)).
14. Reboot: `sudo reboot`. The Pi should land directly on the kiosk.

## Troubleshooting

- **Wi-Fi does not connect after boot, `nmcli con show` lists no Wi-Fi
  profile**: after an unclean power-off, the Wi-Fi profile files
  (`/etc/NetworkManager/system-connections/*.nmconnection`, and
  `/etc/netplan/90-NM-*.yaml`) can be left as 0-byte files because the data
  never reached the stick. Check with `sudo ls -l` on both directories,
  delete the 0-byte files, and recreate the profile without putting the
  password in shell history:

  ```bash
  read -rs -p "Wi-Fi password: " PW; echo
  sudo nmcli con add type wifi ifname wlan0 con-name "AS Home Router" ssid "AS Home Router" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PW" connection.autoconnect yes
  unset PW
  sudo nmcli con up "AS Home Router"; sync
  ```

  `Error: 802-11-wireless-security.key-mgmt: property is missing` from
  `nmcli dev wifi connect` leaves a half-created profile; use the command
  above (or `nmcli con mod ... wifi-sec.key-mgmt wpa-psk`) instead. If the
  log then shows `4way_handshake` followed by `no-secrets`, the stored
  password is wrong. Run `sync` after any change to these files.
- **Stuck at a login prompt / black screen**: check
  `systemctl status getty@tty1` and confirm the override file is in place
  (`systemctl cat getty@tty1`).
- **X fails to start**: run `startx` manually while logged in on tty1 to
  see the error output.
- **Chromium doesn't show the dashboard**: test the URL from a regular
  browser first, then run the `chromium --kiosk --app=...` command manually
  in a terminal (via SSH + `DISPLAY=:0`, plus
  `XAUTHORITY=$(ls -t /tmp/serverauth.* | head -1)`) to see errors.
- **Chromium silently never launches (no process at all, X/openbox fine)**:
  usually a stale `~/.config/chromium/SingletonLock` symlink (left over from
  an unclean shutdown, or pointing at an old hostname/PID after a rename).
  Chromium thinks another instance owns the profile and exits immediately;
  `--noerrdialogs` hides the dialog so nothing visibly happens. Fix:
  `rm ~/.config/chromium/Singleton{Lock,Cookie,Socket}` then relaunch. The
  autostart script now does this automatically before every launch.
- **After a power cycle/reset: Pi is up but no SSH, no espresense-pi web UI,
  and Chromium shows a "can't reach this page" error**: this is a boot-order
  race, not three separate failures. `getty@tty1` autologin (which chains
  into `startx` → `openbox` → Chromium) has no dependency on
  `network-online.target`, but Wi-Fi association + DHCP after a cold boot
  can take several seconds. SSH and the espresense-pi web UI recover on
  their own within a few seconds once the network is actually up (SSH binds
  as soon as `sshd` starts; espresense-pi's systemd unit already waits on
  `network-online.target`). Chromium's `--kiosk`/`--app` mode is the one
  piece that doesn't self-heal: if it loads before the network is ready it
  never retries and just sits on the error page indefinitely. The
  `autostart` script now waits (up to 60s) for the Home Assistant host to
  respond to an HTTP request before launching Chromium, which closes this
  race. If it still happens, check `vcgencmd get_throttled` (undervoltage
  can slow/disrupt Wi-Fi bring-up) and
  `journalctl -b 0 -u NetworkManager -u wpa_supplicant` for how long
  association actually took on that boot.
- **Panel frozen on a static image/clock, doesn't update, and doesn't react
  to touch**: the Chromium process is alive but its renderer has wedged (no
  crash, so nothing auto-recovers). Confirm with a screenshot
  (`DISPLAY=:0 XAUTHORITY=$(ls -t /tmp/serverauth.* | head -1) scrot -o /tmp/x.png`)
  taken a minute apart — if they're byte-identical
  (`cmp -s shot1.png shot2.png`) and touch/mouse input does nothing, it's
  hung. Fix immediately with `pkill -9 -f 'chromium.*--kiosk'` (the
  [watchdog](#5-kiosk-watchdog-auto-recovery) will relaunch it within ~10
  minutes on its own, or relaunch manually with the same
  `chromium --kiosk --app=...` command). The `kiosk-watchdog.timer`
  (section 5) exists specifically to catch this automatically going
  forward — check `sudo journalctl -u kiosk-watchdog.service` to see
  if/when it already did.
- **Panel shows nothing but the mouse cursor (openbox/Xorg running, no
  Chromium window)**: check `pgrep -af chromium` — if there's truly no
  Chromium process, this was caused by a `kiosk-watchdog.service` bug: its
  default `KillMode=control-group` made systemd kill the just-launched
  Chromium the instant the oneshot script exited, every single time the
  watchdog tried to relaunch it, so it could never survive. Fixed by adding
  `KillMode=process` to `kiosk-watchdog.service` (see section 5) so systemd
  only tracks the script itself, not the detached Chromium it spawns. If
  `pgrep -af chromium` shows a process but the screen is still blank, that's
  a different issue — check `journalctl -u kiosk-watchdog.service` and the
  troubleshooting entries above instead.
- **Screen is uniformly black/dark grey (#111) but Chromium is running**: usually
  not a fault. `wallpanel-local` has `idle_time: 0` and is driven by
  `input_boolean.wallpanel_screensaver_local`, which HA motion control turns
  on/off. While it is `off` the view underneath is an empty dashboard (no
  cards), i.e. black, and the watchdog deliberately does nothing. Every fresh
  Chromium start (boot, watchdog relaunch) also leaves the boolean `off`
  until motion control turns it `on`. Check the state with
  `~/bin/kiosk-ha-state.py` (prints `on`/`off`); if it is `on` and the screen
  is still black or frozen, the watchdog will restart Chromium on its next
  run (`sudo journalctl -t kiosk-watchdog`).
- **Screen not rotated / wrong output name**: run `DISPLAY=:0 xrandr`
  to list actual output names and adjust `--output DSI-1` accordingly.
- **Backlight control does nothing**: run `ls /sys/class/backlight/` to
  find the correct device name for the panel and update the path in
  `autostart`.
- **Touch input is mirrored 180° (tapping top-left hits bottom-right)**:
  the screen rotation (`xrandr --rotate`) doesn't auto-apply to the touch
  device. Check `DISPLAY=:0 xinput list-props "10-0038 generic ft5x06 (79)"`
  for an identity `Coordinate Transformation Matrix` — see
  [section 6d](#d-touch-rotation-calibration) for the fix (`xorg.conf.d`
  entry for persistence, `xinput set-prop` to fix the current session
  immediately without restarting X).
- **Tapping a text field shows no on-screen keyboard**: check
  `pgrep -af onboard` — if it's not running, or if it is running but still
  doesn't pop up, see [section 7](#7-on-screen-keyboard-touch-text-input).
  The most common cause is the AT-SPI `IsEnabled` session-bus flag not
  being set (it doesn't persist across reboots/X restarts, so it has to be
  re-sent every login) or the `gir1.2-atspi-2.0` package missing (check
  onboard's stderr for `Atspi typelib missing`).
- **Exit kiosk mode for maintenance**: SSH in and run
  `pkill chromium` (openbox will still be running), or
  `sudo systemctl isolate multi-user.target` briefly won't help since this
  runs on multi-user already — easiest is SSH + `DISPLAY=:0 <command>`.
</content>

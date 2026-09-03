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
    chromium unclutter unclutter-startup
```

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

# Launch Chromium in kiosk mode
# Replace YOUR_HOME_ASSISTANT_URL with the actual URL of your Lovelace dashboard
# Example: http://homeassistant.local:8123/lovelace/main
chromium --noerrdialogs --disable-infobars --kiosk --force-dark-mode --app="http://192.168.178.11:8123/wallpanel-local/0?wp_enabled=true" &
```

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



## 5. Special settings required for the display to work

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

### d. Touch rotation — no manual calibration configured

There is currently **no** `xorg.conf.d` calibration matrix or `xinput`
transform for the `ft5x06` touch device. Since the panel is rotated 180°
via `xrandr` in the kiosk script, modern Xorg + libinput normally
auto-syncs touch coordinates to match the rotated output automatically.
If touch ever ends up inverted/offset after a fresh install, add a config
like this to force it:

```
# /etc/X11/xorg.conf.d/40-touch-rotate.conf
Section "InputClass"
    Identifier "touch-rotate"
    MatchProduct "generic ft5x06"
    Option "TransformationMatrix" "-1 0 1 0 -1 1 0 0 1"
    Driver "libinput"
EndSection
```

(the matrix above is a 180° rotation; adjust for a different orientation).

## Rebuilding from a blank SD card — step by step

1. Flash Raspberry Pi OS, enable SSH, set username `pi`, boot it.
2. Install packages (see [Required packages](#required-packages)).
3. Confirm the boot config lines in [section 5a](#a-boot-config-bootfirmwareconfigtxt)
   are in `/boot/firmware/config.txt` (add if missing), reboot if changed.
4. Confirm `pi` is in the `video` group and the backlight udev rule
   ([section 5c](#c-backlight-write-permission-udev-rule)) exists — needed
   for the brightness line in the kiosk script to work without root.
5. Create the getty autologin override (step 1) and reload systemd.
6. Create `~/.bash_profile` (step 2).
7. Create `~/.xinitrc` and `chmod +x` it (step 3).
8. Create `~/.config/openbox/autostart`, `chmod +x` it, and edit the
   Chromium `--app=` URL to point at your Home Assistant dashboard (step 4).
9. Check the backlight path (`ls /sys/class/backlight/`) and xrandr output
   name (`DISPLAY=:0 xrandr`) match what's used in the autostart script;
   adjust if different. Also verify touch works correctly after the 180°
   rotation ([section 5d](#d-touch-rotation--no-manual-calibration-configured)).
10. Reboot: `sudo reboot`. The Pi should land directly on the kiosk.

## Troubleshooting

- **Stuck at a login prompt / black screen**: check
  `systemctl status getty@tty1` and confirm the override file is in place
  (`systemctl cat getty@tty1`).
- **X fails to start**: run `startx` manually while logged in on tty1 to
  see the error output.
- **Chromium doesn't show the dashboard**: test the URL from a regular
  browser first, then run the `chromium --kiosk --app=...` command manually
  in a terminal (via SSH + `DISPLAY=:0`) to see errors.
- **Screen not rotated / wrong output name**: run `DISPLAY=:0 xrandr`
  to list actual output names and adjust `--output DSI-1` accordingly.
- **Backlight control does nothing**: run `ls /sys/class/backlight/` to
  find the correct device name for the panel and update the path in
  `autostart`.
- **Exit kiosk mode for maintenance**: SSH in and run
  `pkill chromium` (openbox will still be running), or
  `sudo systemctl isolate multi-user.target` briefly won't help since this
  runs on multi-user already — easiest is SSH + `DISPLAY=:0 <command>`.
</content>

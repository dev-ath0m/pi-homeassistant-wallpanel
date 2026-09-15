# ESPresense-Pi Setup (this Pi)

This documents exactly how the `espresense-pi` BLE room-presence node runs
on this Pi, so it can be rebuilt from scratch if the SD card / OS is ever
reflashed.

The application source lives in the separate repo
[dev-ath0m/espresence-rpi](https://github.com/dev-ath0m/espresence-rpi).
This file covers the
**deployment** on this specific machine: paths, service, config values, and
the Home Assistant wiring.

## What it does

It turns this Pi into an ESPresense-compatible presence node: it scans BLE
advertisements, estimates a distance per device, and publishes to MQTT using
the same topic shape as the ESP32 ESPresense firmware — so Home Assistant's
existing ESPresense integration treats it like any other room node.

Current state on this Pi:

| Item | Value |
| --- | --- |
| Room name | `Wohnzimmer` (slug `wohnzimmer`) |
| Install dir | `/opt/espresense-pi` |
| Service | `espresense-pi.service` (enabled at boot, runs as `root`) |
| Web UI | `http://192.168.178.20:8080` |
| MQTT broker | `192.168.178.6:1883` |
| Bluetooth adapter | `hci0` (onboard, UART) |

```mermaid
flowchart LR
    A[BLE advertisements] --> B[bleak scanner<br/>hci0]
    B --> C[distance estimate<br/>RSSI + path loss]
    C --> D[espresense/devices/&lt;id&gt;/wohnzimmer]
    C --> E[Flask web UI :8080]
    D --> F[MQTT broker<br/>192.168.178.6]
    F --> G[Home Assistant<br/>ESPresense integration]
```

## Why root?

The service runs as `User=root` because it needs raw access to the Bluetooth
adapter (`rfkill unblock`, `hciconfig hci0 up`, and BlueZ scanning via
D-Bus). Running unprivileged is possible with `CAP_NET_ADMIN` +
`CAP_NET_RAW` and a BlueZ D-Bus policy, but that's not what's configured
here.

## 1. Install

Clone the repo and run the installer — it handles apt dependencies, the
venv, the config file, and the systemd unit:

```bash
git clone git@github.com:dev-ath0m/espresence-rpi.git ~/espresense-pi
cd ~/espresense-pi
sudo ./scripts/install.sh
```

What the installer does:

1. `apt-get install bluetooth bluez python3-venv python3-pip rsync`
2. `rsync` the repo to `/opt/espresense-pi` (excluding `venv`, `.git`,
   `__pycache__`)
3. Create `/opt/espresense-pi/venv` and `pip install -r requirements.txt`
4. Copy `config.example.yaml` → `config.yaml` **only if it doesn't exist**
   (so your settings survive re-installs)
5. Install, enable and start `espresense-pi.service`

Python dependencies: `bleak`, `paho-mqtt`, `Flask`, `waitress`, `PyYAML`,
`psutil`, `pycryptodome` (the last one is used for IRK resolution of
privacy-enabled devices like iPhones).

## 2. The systemd unit

File: `/etc/systemd/system/espresense-pi.service`

```ini
[Unit]
Description=ESPresense-Pi BLE presence detection service
After=network-online.target bluetooth.target
Wants=network-online.target
Requires=bluetooth.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/espresense-pi
Environment=ESPRESENSE_PI_HOME=/opt/espresense-pi
Environment=PYTHONUNBUFFERED=1
ExecStartPre=-/usr/sbin/rfkill unblock bluetooth
ExecStartPre=-/usr/bin/hciconfig hci0 up
ExecStart=/opt/espresense-pi/venv/bin/python -m espresense_pi.main
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

The two `ExecStartPre` lines are prefixed with `-` so a failure doesn't
block startup. They exist because after a cold boot the adapter is
occasionally still soft-blocked by rfkill or left down.

## 3. Configuration

File: `/opt/espresense-pi/config.yaml` (owned by root, editable through the
web UI). Current values:

```yaml
room:
  name: Wohnzimmer
mqtt:
  host: 192.168.178.6
  port: 1883
  username: ''
  password: '<redacted>'
  base_topic: espresense
  discovery: true
  discovery_prefix: homeassistant
  pub_tele: true
  pub_devices: true
ble:
  ref_rssi: -65          # RSSI at 1 m for unknown devices
  tx_ref_rssi: -59       # assumed transmit power reference
  absorption: 2.7        # path-loss exponent; higher = more walls/bodies
  rx_adj_rssi: 0         # per-node receiver calibration offset
  max_distance: 6.0      # ignore devices beyond this many metres
  skip_distance: 0.5     # don't republish unless distance moved this far
  skip_ms: 5000          # ...or this long has passed
  forget_ms: 150000      # drop a device after this long unseen
  include: ''
  exclude: ''
  known_macs: ''
  count_ids: ''
  count_enter: 2.0
  count_exit: 4.0
  count_ms: 10000
web:
  host: 0.0.0.0
  port: 8080
```

Enrolled devices are stored separately in
`/opt/espresense-pi/devices.json`.

### Calibration tips

- `absorption` is the main knob. `2.0` is roughly free air; raise it toward
  `3.0`+ for a room with furniture and walls between node and device.
- Calibrate by placing a phone exactly 1 m from the Pi and adjusting
  `ref_rssi` until the reported distance reads ~1.0 m, *then* tune
  `absorption` at 4–5 m.
- `max_distance` should be a little larger than the room, otherwise devices
  flicker in and out at the edges.

## 4. MQTT topics

| Topic | Retained | Payload |
| --- | --- | --- |
| `espresense/rooms/wohnzimmer/status` | yes | `online` / `offline` (Last Will) |
| `espresense/rooms/wohnzimmer/name` | yes | `Wohnzimmer` |
| `espresense/rooms/wohnzimmer/<setting>` | yes | current BLE setting value |
| `espresense/rooms/wohnzimmer/telemetry` | no | `{"uptime","ver","firm","ip","rssi","freeMem","cpuPct"}` (every 30 s) |
| `espresense/devices/<id>/wohnzimmer` | no | `{"id","distance","rssi","mac","name"}` |
| `espresense/rooms/+/<setting>/set` | — | **subscribed**: change a setting at runtime |
| `espresense/settings/<id>/config` | — | **subscribed**: device enrollment sync |
| `homeassistant/binary_sensor/espresense_pi_wohnzimmer/status/config` | yes | HA MQTT discovery |

Handy inspection commands:

```bash
sudo apt install -y mosquitto-clients

# Retained room state
mosquitto_sub -h 192.168.178.6 -v -t 'espresense/rooms/wohnzimmer/#'

# Live device stream
mosquitto_sub -h 192.168.178.6 -v -t 'espresense/devices/+/wohnzimmer'

# Change a setting at runtime (also persisted to config.yaml)
mosquitto_pub -h 192.168.178.6 -t 'espresense/rooms/wohnzimmer/absorption/set' -m '3.0'
```

## 5. Web UI

`http://192.168.178.20:8080` — `/` redirects to `/network`. Pages:

| Path | Purpose |
| --- | --- |
| `/network` | MQTT broker host/port/credentials |
| `/settings` | Room name and BLE tuning values |
| `/devices` | Enroll, pair and delete tracked devices |
| `/json` | ESPresense-compatible node info |
| `/json/devices` | Current device list with distance, RSSI, last seen |

There is **no authentication** on this UI, and it binds to `0.0.0.0`.
Keep it on the trusted LAN only — never port-forward `8080`.

Quick health check from the shell:

```bash
curl -s http://127.0.0.1:8080/json/devices | python3 -m json.tool
```

## 6. Home Assistant

With `discovery: true`, the node publishes an MQTT discovery config and
appears automatically as a `connectivity` binary sensor named
**ESPresense-Pi (Wohnzimmer)**.

Device tracking itself comes from the ESPresense integration in HA, which
consumes `espresense/devices/<id>/<room>` from every room node and picks the
closest one. Enroll a device here under `/devices` using the same ID that
your other ESPresense nodes use, so HA sees a single device reported by
multiple rooms.

### ESPresense Companion "Nodes" view

If you also run ESPresense Companion, its **Nodes** table is built entirely
from the room telemetry topic:

| Column | Source |
| --- | --- |
| Version | telemetry `ver` |
| IP | telemetry `ip` |
| Flavor | first flavor in `types.json` whose `value` is a suffix of telemetry `firm` |
| CPU | firmware entry named `<firm>.bin` in `types.json`, mapped to its CPU |

Companion downloads that lookup table from
<https://espresense.com/firmware/types.json>, which only lists the four
ESP32 variants and their official firmware binaries. Because this node
reports `firm: "rpi"` — which deliberately matches no ESP32 firmware — the
**CPU column stays `n/a`** and **Flavor falls back to `Standard`**.

That is intentional: claiming an ESP32 firmware name would make Companion
offer OTA firmware updates and try to flash an ESP32 image onto a
Raspberry Pi. The missing **Update** button on this node's row is the
safety net working as designed.

## Maintenance

```bash
# Status and live logs
systemctl status espresense-pi
sudo journalctl -u espresense-pi -f

# Deploy code changes from the working copy
cd ~/espresense-pi
sudo ./scripts/install.sh          # rsyncs and restarts; keeps config.yaml

# Bluetooth adapter sanity check
hciconfig hci0
sudo systemctl restart bluetooth && sudo systemctl restart espresense-pi

# Remove completely
sudo ~/espresense-pi/scripts/uninstall.sh
```

Note that `journald` is configured for **persistent** storage on this Pi
(`/var/log/journal` exists), so logs survive reboots:

```bash
sudo journalctl -u espresense-pi -b -1 --no-pager   # previous boot
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Companion's Nodes view shows `n/a` for Version/IP | The node isn't publishing `ver`/`ip` in its telemetry — check `mosquitto_sub -h 192.168.178.6 -v -t 'espresense/rooms/wohnzimmer/telemetry'` |
| Companion's Nodes view shows `n/a` for CPU | Expected — Companion can only resolve the four ESP32 CPUs from the official firmware manifest (see above) |
| HA shows the room **disconnected** but device messages keep arriving | Stale retained Last Will. The broker publishes `offline` only when it reaps the dead session, which can land *after* the client reconnected and published `online`. Fixed by re-asserting the retained `online` status on every telemetry tick — verify with `mosquitto_sub -h 192.168.178.6 -v -t 'espresense/rooms/wohnzimmer/status'` |
| `MQTT disconnected rc=16` in the log | paho keepalive (30 s) timeout — a transient network hiccup or broker restart. Harmless if a reconnect line follows within seconds |
| No devices detected at all | Adapter down or soft-blocked: `sudo rfkill unblock bluetooth && sudo hciconfig hci0 up` |
| Distances consistently too large/small | Recalibrate `ref_rssi` at 1 m, then `absorption` |
| iPhone/Apple Watch keeps changing MAC | Expected (BLE privacy). Enroll it by **IRK** instead of MAC — pair the device via `/devices` so the IRK can be read |
| Service won't start after reflash | Adapter is named something other than `hci0`, or the venv was rebuilt against a different Python — re-run `scripts/install.sh` |

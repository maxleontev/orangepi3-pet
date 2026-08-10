# WiFi stack (AP6256 / brcmfmac)

Recipes under `recipes-wifi/` bring up Orange Pi 3 WiFi (AP6256), persist
client credentials on `/data`, and fall back to an open **setup AP** with a web
UI when STA cannot join a router.

| Recipe | Role |
|--------|------|
| `wifi-init/` | `wifi.service` / `wifi-roam.service`, scripts, setup web UI, lighttpd config |
| `fw-ap6256/` | Board-specific brcmfmac NVRAM (`brcmfmac43456-sdio.txt`) |

Related pieces outside this folder:

| Piece | Location |
|-------|----------|
| Factory seed `/data/wifi.conf` | `core-image-khepri.bb` (`khepri_gpt_rootfs_layout`) |
| Image packages | `core-image-khepri.bb` → `wifi-init hostapd dnsmasq` (+ lighttpd via `RDEPENDS`) |
| Machine WiFi module | `conf/machine/orange-pi-3.conf` → `brcmfmac` |

---

## Runtime modes

### STA (normal)

1. `wifi.service` → `/usr/sbin/wifi-connect`
2. Reads `/data/wifi.conf` (wpa_supplicant format)
3. Associates, runs DHCP (`udhcpc`), writes `/run/wifi-mode=sta`
4. `wifi-roam` may switch among configured SSIDs by measured RSSI

### Setup AP (fallback)

Triggered when `/data/wifi.conf` has no `network={}` blocks, or STA
association/DHCP fails:

1. `/usr/sbin/wifi-ap-start` → hostapd + dnsmasq + lighttpd
2. Open SSID `Khepri-Setup-<mac4>`, web UI on the setup AP address
3. `/run/wifi-mode=ap`

Default setup address is **`192.168.4.1`**, stored in `/data/wifi.conf`:

```
# setup_ap_ip=192.168.4.1
# setup_ap_prefix=24
```

Change these lines and `systemctl restart wifi` to use another AP IP. dnsmasq
is generated at runtime under `/run/` from that address (not stored on `/data`).

---

## `/data/wifi.conf`

Persistent STA settings (A/B rootfs swaps must not wipe them):

- wpa_supplicant globals + `network={}` blocks
- `# setup_ap_ip=` / `# setup_ap_prefix=` (setup AP gateway)

Written by the setup web UI (`wifi-write-config`) or by hand. Empty networks →
setup AP at boot. Legacy `/data/wpa_supplicant.conf` is migrated once to
`wifi.conf`.

Ephemeral files (`hostapd`, lighttpd) live under `/run`, not `/data`.

---

## Setup web UI

Served by lighttpd from `/usr/share/wifi-setup/` while in AP mode:

| Path | Purpose |
|------|---------|
| `/` | Network list (scan) + credentials form |
| `/cgi-bin/scan` | JSON SSID list |
| `/cgi-bin/test` | Start a **temporary** STA connection test (does not save) |
| `/cgi-bin/test-status` | JSON result of last test |
| `/cgi-bin/save` | Write `/data/wifi.conf` and `systemctl restart wifi` |

**Test connection** (max ~20s) tears down the setup AP briefly, tries the
chosen SSID/PSK on `wlan0`, then brings the setup AP back and reports
Connected / Not connected. The browser may disconnect; rejoin
`Khepri-Setup-*` to see the result. Credentials are not saved until **Save
and connect**.

---

## On-target tools

| Command | Role |
|---------|------|
| `/usr/sbin/wifi-connect` | Boot/oneshot STA or setup AP |
| `/usr/sbin/wifi-ap-start` / `wifi-ap-stop` | Setup AP lifecycle |
| `/usr/sbin/wifi-write-config` | Write `ssid:psk` pairs into `/data/wifi.conf` |
| `/usr/sbin/wifi-scan` | Scan / cache SSIDs for the UI |
| `/usr/sbin/wifi-test-connect` | Background STA test used by CGI |
| `/usr/sbin/wifi-roam` | Prefer stronger configured BSS |

Useful env overrides: `IFACE`, `CONF`, `AP_IP`, `AP_PREFIX`, `AP_FALLBACK`,
`SKIP_SCAN=1` (skip pre-AP `iw scan` when restoring AP after a test).

---

## Layout

```
recipes-wifi/
├── README.md                 ← this file
├── fw-ap6256/
│   ├── fw-ap6256_0.1.bb
│   └── files/brcmfmac43456-sdio.txt
└── wifi-init/
    ├── wifi-init.bb
    └── files/
        ├── wifi.service / wifi-roam.service
        ├── wifi-connect.sh / wifi-roam.sh
        ├── wifi-ap-start.sh / wifi-ap-stop.sh
        ├── wifi-write-config.sh / wifi-scan.sh / wifi-test-connect.sh
        ├── wifi-conf-lib.sh / wifi.conf / lighttpd.conf
        └── www/                  ← setup UI + CGI
```

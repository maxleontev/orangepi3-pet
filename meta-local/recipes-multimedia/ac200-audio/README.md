# AC200 analog microphone (`ac200-audio`)

Single recipe for Orange Pi 3 onboard MIC1 (X-Powers AC200 on I2S3).

| Piece | Where |
|-------|--------|
| Userspace mixer + `amixer`/`arecord`/`aplay` | `ac200-audio.bb` → image package `ac200-audio` |
| `ac200-mic-hdmi-play` (MIC1 → HDMI) | `/usr/sbin/ac200-mic-hdmi-play` — [root README](../../../../README.md#ac200-mic-hdmi-play) |
| Host wrapper | [`run-ac200-mic-hdmi-play.sh`](../../scripts/README.md#run-ac200-mic-hdmi-play) |
| Kernel fragments and patches | `ac200-audio-kernel.inc` (included from `linux-mainline_%.bbappend`) |
| Mixer defaults | `files/ac200-mic-setup.sh` — ADC Volume **7**, Master cap **62%**, MIC1 Boost **3**. Waits until `amixer` can open card `ac200audio` (boot used to hit `Invalid card number '0'` and leave capture off). |
| HDMI ALSA card | DTS patch `0005-…-enable-HDMI-audio.patch` → card `allwinner-hdmi`; `dw_hdmi_i2s_audio` loaded by `weston-prepare-drm` after WiFi |

The image installs **`ac200-audio` only**; ALSA utils come in via `RDEPENDS`.
`info-panel` also `RDEPENDS` this package so the HDMI spectrum has a configured card.

Not the LTS AC200-EPHY Ethernet PHY stack.

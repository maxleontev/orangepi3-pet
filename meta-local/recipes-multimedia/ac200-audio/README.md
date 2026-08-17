# AC200 analog microphone (`ac200-audio`)

Single recipe for Orange Pi 3 onboard MIC1 (X-Powers AC200 on I2S3).

| Piece | Where |
|-------|--------|
| Userspace mixer + `amixer`/`arecord`/`aplay` | `ac200-audio.bb` → image package `ac200-audio` |
| Kernel fragments and patches | `ac200-audio-kernel.inc` (included from `linux-mainline_%.bbappend`) |
| Mixer defaults | `files/ac200-mic-setup.sh` — ADC Volume **7**, Master cap **62%**, MIC1 Boost **4** |

The image installs **`ac200-audio` only**; ALSA utils come in via `RDEPENDS`.
`info-panel` also `RDEPENDS` this package so the HDMI spectrum has a configured card.

Not the LTS AC200-EPHY Ethernet PHY stack.

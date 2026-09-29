# Onboard Ethernet (RTL8211E / `eth-init`)

Orange Pi 3 (non-LTS) uses an external Realtek RTL8211E on RGMII, not the
LTS AC200-EPHY path. Mainline leaves `&emac` disabled for this board; the
pieces below enable the MAC/PHY, autoload drivers, and run DHCP at boot.
Getting a reliable link took a long DTS/power/reset pass — details are in
[Hardware and DTS](#hardware-and-dts).

| Piece | Location |
|-------|----------|
| Machine modules | [`conf/machine/orange-pi-3.conf`](../../conf/machine/orange-pi-3.conf) → `dwmac_sun8i`, `realtek` |
| DTS enable | [`0001-arm64-dts-orangepi-3-enable-ethernet.patch`](../../recipes-kernel/linux/files/0001-arm64-dts-orangepi-3-enable-ethernet.patch) (via `linux-mainline_%.bbappend`) — RGMII, 2.5 V IO, PHY reset |
| Userspace DHCP | this recipe → `eth.service` + `/usr/sbin/eth-connect` |
| Image package | `core-image-khepri.bb` → `eth-init` |

On-target usage: [root README — `eth-connect`](../../../README.md#eth-connect).

---

## Boot path

1. Kernel loads `dwmac_sun8i` + Realtek PHY (`KERNEL_MODULE_AUTOLOAD` in the
   machine conf). The board DTB must already describe `&emac` correctly
   (see below).
2. `eth.service` (oneshot, after modules) runs `/usr/sbin/eth-connect`.
3. Script picks the first wired iface (`IFACE=`, else `eth0` / `end0`, else
   first non-wireless netdev), waits for carrier, runs `udhcpc`, and sets the
   default route metric (`DHCP_METRIC`, default `50`) so onboard Wi‑Fi can
   stay preferred when both are up.

Not from stock `orange-pi-3lts`: that machine conf has no Ethernet knobs;
LTS hardware differs.

---

<a id="hardware-and-dts"></a>
## Hardware and DTS

Orange Pi 3 LTS uses a different PHY path (AC200-EPHY). Non-LTS is an
external **RTL8211E** on the SoC RGMII pins. Layout follows the sunxi
“enable orangepi-3 ethernet” series, adapted for kernel 6.6.

### RGMII (SoC ↔ PHY on the PCB)

**RGMII** is the on-board bus between the H6 MAC (`&emac` / `dwmac_sun8i`)
and the RTL8211E. It is not USB and not Wi‑Fi: copper traces on the PCB
carry Gigabit signalling to the RJ45 magnetics.

The MAC node uses the SoC pinmux group `ext_rgmii_pins` and points at the
PHY on MDIO address 1:

- `phy-mode = "rgmii-id"` — delay is applied in the **PHY**, not in the MAC
  (internal delay). Wrong mode (e.g. plain `rgmii` or `rgmii-txid`) often
  gives no link or a flaky link at 1 G.
- `phy-handle = <&ext_rgmii_phy>`
- `compatible` on the PHY includes `ethernet-phy-id001c.c915` (RTL8211E)

### 2.5 V RGMII I/O (`gmac-2v5`, PD6)

RGMII **signal** levels on this board are **2.5 V**, not 3.3 V. A fixed
regulator `reg_gmac_2v5` / `gmac-2v5` is enabled with GPIO **PD6**
(`enable-active-high`), supplied from the 5 V rail (`vin-supply = &reg_vcc5v`),
with `off-on-delay-us = <100000>`.

That regulator is attached as `phy-supply` on **`&emac`**. Driver
`dwmac-sun8i` turns it on when bringing up the MAC, which powers the 2.5 V
RGMII I/O domain. Without it, the link may never come up or may look
“almost configured” with no carrier.

Separately, the PHY’s **3.3 V** analog/rail side uses always-on **ALDO2**,
shared with audio (`vcc33-audio-tv-ephy-mac` in the board DTS). That is not
the same net as `gmac-2v5`.

**Kernel 6.6 note:** there is no usable `phy-io-supply` path in the PHY core
for this setup, so the 2.5 V enable stays on `&emac` as `phy-supply` (see
patch header). Do not “clean up” by moving it onto the PHY node without
re-checking that `gmac-2v5` still turns on before RGMII traffic.

### PHY reset (PD14)

RTL8211E has an active-low reset pin wired to GPIO **PD14**. The DTS sets:

- `reset-gpios = <&pio 3 14 GPIO_ACTIVE_LOW>`
- `reset-assert-us = <15000>`
- `reset-deassert-us = <40000>`

The kernel must assert/deassert this at probe so the PHY leaves reset in a
known state. Missing or wrong reset GPIO is a classic “no PHY / no carrier”
failure after the MAC looks fine.

### Extra PHY quirks in the same node

- `eee-broken-100tx` / `eee-broken-1000t` — disable broken Energy-Efficient
  Ethernet modes on this PHY (also from the sunxi enable series).

### Drivers (machine conf)

`KERNEL_MODULE_AUTOLOAD` adds `dwmac_sun8i` (H6 MAC) and `realtek` (PHY).
Userspace (`eth-connect`) only runs after those modules and the DTB above
are correct; DHCP cannot fix a dead link.

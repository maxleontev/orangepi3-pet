# dnsmasq is started on demand by wifi-ap-start with a dedicated AP config.
# Do not run the stock system instance at boot (conflicts on wlan0).
SYSTEMD_AUTO_ENABLE = "disable"

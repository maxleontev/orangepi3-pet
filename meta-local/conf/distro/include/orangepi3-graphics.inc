# Wayland/Weston + Mesa Lima (Mali-T720) for Orange Pi 3.
# Include from local.conf: require conf/distro/include/orangepi3-graphics.inc

DISTRO_FEATURES:append = " wayland opengl pam"
DISTRO_FEATURES:remove = "x11"

# Which fullscreen HDMI client core-image-khepri installs (exactly one):
#   stats  — info-panel (CPU/mem/IP + AC200 mic spectrum)  [default]
#   camera — info-panel-camera (live USB UVC preview)
# Override in local.conf, e.g. INFO_PANEL = "camera"
INFO_PANEL ??= "stats"

# Mainline Lima instead of proprietary sunxi-mali binaries.
PREFERRED_PROVIDER_virtual/egl = "mesa"
PREFERRED_PROVIDER_virtual/libgles1 = "mesa"
PREFERRED_PROVIDER_virtual/libgles2 = "mesa"
PREFERRED_PROVIDER_virtual/libgl = "mesa"
PREFERRED_PROVIDER_virtual/mesa = "mesa"
PREFERRED_PROVIDER_virtual/libgbm = "mesa"

# Stay on multi-user so networking/SSH come up even if Weston/DRM fails.
# Weston and info-panel are WantedBy=multi-user.target (see their units).
SYSTEMD_DEFAULT_TARGET = "multi-user.target"

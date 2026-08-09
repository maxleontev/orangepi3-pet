project('info-panel', 'c', version: '1.0.0', default_options: ['warning_level=2', 'c_std=c11'])

wayland_client = dependency('wayland-client')
wayland_protos = dependency('wayland-protocols', version: '>=1.15')
cairo = dependency('cairo')

wayland_scanner_prog = find_program('wayland-scanner', native: true)
protocols_dir = wayland_protos.get_variable('pkgdatadir')

xdg_shell_xml = join_paths(protocols_dir, 'stable', 'xdg-shell', 'xdg-shell.xml')

xdg_shell_client_header = custom_target(
  'xdg-shell-client-header',
  input: xdg_shell_xml,
  output: 'xdg-shell-client-protocol.h',
  command: [wayland_scanner_prog, 'client-header', '@INPUT@', '@OUTPUT@'],
)

xdg_shell_private_code = custom_target(
  'xdg-shell-private-code',
  input: xdg_shell_xml,
  output: 'xdg-shell-protocol.c',
  command: [wayland_scanner_prog, 'private-code', '@INPUT@', '@OUTPUT@'],
)

executable(
  'info-panel',
  'info-panel.c',
  xdg_shell_client_header,
  xdg_shell_private_code,
  dependencies: [wayland_client, cairo],
  install: true,
)

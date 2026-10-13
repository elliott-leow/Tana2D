# Tana2D verification

This record covers the separate Tana2D fork. Historical Tana evidence is retained
in [TANA-VERIFICATION.md](TANA-VERIFICATION.md); it is not evidence that the new
plane implementation works.

## Checked on October 13, 2026

- `make all test live-tools` passed on this Mac. The build retains warnings for
  unused legacy strip functions.
- Thirteen native test executables passed, including sanitizer-backed geometry,
  plane rendering, independent native resizing, transform cleanup, undo, configuration,
  setup policy, accessibility semantics, and camera-control callbacks.
- All 20 Python packaging/session tests passed.
- Native camera controls were rendered offscreen and visually inspected.
- Signed packaging, deep/strict signature verification, and installation at
  `/Applications/Tana2D.app` passed.
- Installer rejection tests protect the original Tana bundle identity.
- The original installed Tana executable hash was checked against the saved hash.
- `git diff --check` passed.

## Project isolation

The separate repository is `elliott-leow/Tana2D`. Bundle identity, executable,
configuration/layout directory, IPC sockets, privileged helper, and scripting
addition installation are separate from Tana. The shared manager lock prevents
simultaneous window management. Neither Tana nor HorizontalWM state is imported.

## Live acceptance pending

The installed setup check reports the desktop locked, the new helper absent,
and the original Tana manager still running. Tana2D has not taken over window
management. macOS administrator approval for its helper and an unlocked desktop
are required before live acceptance can run.

`make live-tools` builds disposable fixture windows and measurement/input probes.
`python3 tests/live_plane_check.py` is the proposed live acceptance harness. It
checks signed world positions, camera travel in four quadrants, native transforms,
zoom, movement/undo, dragging, generated swipe/pinch events, and fit-all geometry.
It has not been run against an active Tana2D session. The older `live_*` harnesses
were inherited from Tana and may assert strip-specific behavior.

Generated input and automated checks do not establish physical trackpad feel,
VoiceOver usability, login/reboot persistence, or behavior on other macOS versions.

# Tana2D verification

This record covers the separate Tana2D fork. Historical Tana evidence is retained
in [TANA-VERIFICATION.md](TANA-VERIFICATION.md).

## Checked on October 13, 2026

- `make all test` passed: 15 native test executables and 20 Python tests. The build
  retains nine warnings for unused legacy strip functions.
- Gesture tests cover 24 directions at two zoom levels, stable finger identities,
  changed contact order, finger lifts/replacements, stale frames, and independent
  devices. Screen movement follows the sensor's right/up coordinates, with the
  vertical sign converted to screen coordinates. Dock's one-axis progress no
  longer drives the camera. Raw touches stay in memory and are not logged.
- Native tests cover real initial dimensions, independent resize, zoomed edge hit
  testing, magnetic adjacency, position notifications without unnecessary resize,
  repeated absolute transforms against the helper's toggle protocol, and reset.
- Signed packaging, deep/strict signature verification, and installation at
  `/Applications/Tana2D.app` passed. The original Tana executable remains unchanged.
- Native camera controls were rendered and visually inspected; Fit all and 100%
  were also exercised against the running manager.
- Live WindowServer checks passed for signed world positions, camera movement in
  all four quadrants, inverse screen translation, zoom in/out, movement/undo,
  fit-all without rearrangement, repeated fit, and native-transform reset.
- External `borders` surfaces were observed at zero alpha while Tana2D owns the
  desktop. Tana2D draws one focused outline and restores external alpha on quit.

## Latest repair status and unresolved behavior

A live trace reproduced the native-frame conflict: Firefox’s projected top edge
was -246 points while macOS clamped its native top edge to 38 points, producing
an approximately 284-point discrepancy. The previous renderer moved the native
frame during pan, allowing AppKit and the camera to compete over placement.

Version 0.5.0 replaces those moves with absolute compositor transforms. A helper
packet applies all window and focus-outline transforms in one transaction.
Native frames remain anchors; world and displayed positions are tracked
separately. Runtime regressions exercise 80 two-axis pan steps, an injected
native clamp, and 121 drag projections with zero native moves or pan resizes.
The helper validates packet lengths, finite transforms, and capability/version.

Camera commands now animate viewport center and logarithmic zoom together.
Command+Shift+Return animates maximize. Control+Return fits the canvas and accepts
a window click to center that window at 100% without resizing it. Escape cancels
selection. These transitions respect Reduce Motion.

The full build, 15 native test executables and 20 Python tests passed. Signed
packaging and installation passed. Activation currently awaits macOS administrator
authentication for updating the existing window helper. No live result for 0.5.0
is claimed yet. The earlier manager was shut down normally and restored windows.

The previous interactive build reached a 51.093 ms frame and a 60 Hz display
callback. macOS reports a 60 Hz active mode and all enumerated modes report 60 Hz.
Sustained 120 fps and glitch-free physical interaction remain unverified.
Title-bar/Option-drag handoff, magnetic snapping, visual motion, and the new
click-to-center workflow still require live acceptance of the updated backend.

`make live-tools` builds disposable fixture windows and measurement probes.
`python3 tests/live_plane_check.py` checks live native geometry without generating
input. It restores camera/focus and closes only its disposable fixture windows.
The optional generated-input probes do not establish physical trackpad behavior.
Older `live_*` harnesses were inherited from Tana and may assert strip behavior.

No login/reboot, VoiceOver, other-hardware, or other-macOS-version acceptance is
claimed. The MultitouchSupport bridge uses a private macOS interface.

## Project isolation

Repository: `elliott-leow/Tana2D`. Bundle identity, executable, configuration/layout
directory, IPC sockets, privileged helper, and scripting addition paths are
separate from Tana. The shared manager lock prevents simultaneous management.
Tana/HorizontalWM state is not imported. Layout version 3 ignores invalid size
caches from version 2 and recovers actual native dimensions.

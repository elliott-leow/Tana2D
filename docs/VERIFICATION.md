# Tana2D verification

This record covers the separate Tana2D fork. Historical Tana evidence is retained
in [TANA-VERIFICATION.md](TANA-VERIFICATION.md).

## Checked on October 13, 2026

- `make all test` passed: 15 native test executables and 20 Python tests. The build
  retains seven warnings for unused legacy strip functions.
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

The user still reports jumping during scrolling and broken dragging/snapping.
Earlier geometry passes do not establish that these visible failures are fixed.
The latest build passes `make all test` (15 native executables and 20 Python
checks), including actual-size maximize, scale-preserving pan, exact-edge snap
retention, fast continuous gesture samples, and native-size initialization.

Recent changes keep a pan's native transform in place, move the focused outline
in the presentation batch, avoid display-geometry queries during dragging, and
add Command+Shift+Return for 100% zoom plus a window filling the usable screen.
Exact-edge snapping now retains its neighbor and eases the displayed position,
preventing the correction offset from pushing a window past the acquired edge.

The last interactive build recorded a 51.093 ms maximum frame and a 60 Hz display
callback. macOS reports a 60 Hz active mode, and all enumerated display modes
report 60 Hz. Neither sustained 120 fps nor glitch-free physical interaction is
verified. A 45-second passive trace contained no movement and therefore did not
reproduce the reported problem. The desktop then locked; Tana2D reports suspended
input. The latest repair is installed on disk; restart and live acceptance await
an unlocked desktop. The prior manager process remains running.

Remaining work: reproduce a physical scroll and title-bar/Option drag, correlate
visible jumps with native geometry, verify acquired-edge retention on screen,
and investigate the initial AppKit drag handoff if it still moves the surface
before Tana2D takes ownership. Automated pointer routing did not exercise that
physical input path and is not counted as acceptance.

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

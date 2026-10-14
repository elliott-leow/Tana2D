# Tana2D verification

This record covers the separate Tana2D fork. Historical Tana evidence is retained
in [TANA-VERIFICATION.md](TANA-VERIFICATION.md).

## Earlier checks on October 13, 2026

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

Version 0.5.1 replaces those moves with absolute compositor transforms. A helper
packet applies all window and focus-outline transforms in one transaction.
Native frames remain fixed during pan, zoom, and plane dragging; world and
displayed positions are tracked separately. A growing resize may reposition its
native anchor inside the usable screen in the same presentation batch, because
AppKit limits AX size to the space remaining after that anchor. Runtime regressions exercise 80 two-axis pan steps, an injected
native clamp, and 121 drag projections with zero native moves or pan resizes.
The helper validates packet lengths, finite transforms, and capability/version.

Camera commands now animate viewport center and logarithmic zoom together.
Command+Shift+Return animates maximize. Control+Return fits the canvas and accepts
a window click to center that window at 100% without resizing it. Escape cancels
selection. These transitions respect Reduce Motion.

The full build, 15 native test executables and 20 Python tests passed. Signed
packaging, installation, administrator helper update, and activation passed.
Version 0.5.1 is running with `ready:true`, `backend:true`, and no move failures.
The live geometry harness passed all ten checks, including fixed native anchors
during pan, zoom in/out, fit-all, undo, and maximize to the usable screen.

An additional live transaction test uses its own disposable NSWindow to verify
12 absolute projections and unchanged native anchors. This caught an incorrect
private-API return declaration: transform and commit calls do not supply a
CGError result on this Mac. Their submission is now acknowledged without treating
undefined return-register contents as an error; live geometry verifies application.

The previous interactive build reached a 51.093 ms frame and a 60 Hz display
callback. macOS reports a 60 Hz active mode and all enumerated modes report 60 Hz.
Sustained 120 fps and glitch-free physical interaction remain unverified.
Title-bar/Option-drag handoff, magnetic snapping, visual motion, and the new
click-to-center workflow still require physical acceptance of the updated backend. A 75-second passive
recording contained 1,644 samples but no camera or drag input, so it is not counted
as physical acceptance. App-targeted automation did not reach the global event tap.
The production selection handler is covered for empty space, displayed geometry,
topmost-window hits, centering at 100%, and preservation of window dimensions.
A live selection-animation sample captured 17 successive states with intermediate
zoom values and unchanged native anchors and dimensions.

`make live-tools` builds disposable fixture windows and measurement probes.
`build/live_transform_transaction` checks native transaction behavior using its own
disposable window. `python3 tests/live_plane_check.py` checks live native geometry without generating
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

## Input update on October 14, 2026

Control+Up now invokes the same selection mode as Control+Return. Four-finger
vertical swipes invoke it once per contact session; tests cover both directions,
contact reordering/replacement, stale frames, multiple devices, horizontal motion,
and finger-lift suppression. Three-finger pan release eases the camera toward the
window under the pointer, preserves zoom, and does not activate or resize it.
Empty canvas remains in place. `settings.magneticCentering` controls that behavior.

Hover focus and focus-after-scroll are off in the local configuration. Synthetic
focus-event records now use per-call buffers instead of a shared mutable buffer
across the event loop and focus queue. This removes a code-level race; it does not
establish that the user's reported phantom-key behavior was reproduced.
Command+Return opens Terminal and Command+Shift+W opens Firefox explicitly.

This update passed `make all test` (15 native executables and 20 Python tests),
signed packaging, installation, and startup. Live checks confirmed the selection
alias enters selection mode without changing world geometry, hover focus is off,
there are no shortcut conflicts or helper move failures, and the launcher actions
activate Terminal and Firefox. Physical four-finger recognition and magnetic feel
remain unverified; app-targeted automation bypasses the global input tap.


## Resize and overview follow-up on October 14, 2026

The magnetic camera adjustment now applies only within 120 display points of the
center, never exceeds 12 display points per pan release, and never opposes a pan
away from the center. Tests cover the cap and escape behavior at five zoom levels.
Four-finger up opens the chooser; down centers the active window at 100 percent.
Overview presses now wait until release to select. A movement of five display
points starts a regular plane drag, preserving world dimensions and staying in
the overview after release. Production controller tests cover click, movement
threshold, drag, zoom conversion, and unchanged native dimensions.

Live testing reproduced an app resize that changed native width while the stored
world width stayed stale. AX resize notifications can precede the WindowServer
bounds update. The renderer now samples for 150 ms after a notification, preserves
the cached projection scale while invalidating the transform, and adopts the
accepted native size without an AX resize echo. The existing idle reconciliation
also compares dimensions, covering missing or early notifications. Native edge
resize keeps the opposite edge fixed using native dimensions in world units.
The border measures the current native surface instead of an asynchronous target
size. `strip presentation-status <id>` reports the relevant geometry and pending
state without window titles or input contents.

`make all test` passes (15 native test executables and 20 Python tests). The live
geometry harness now includes four app-originated grow/shrink resizes at 100% and
50% zoom, with world/native dimensions, absolute projection, and border bounds
checked together. All 11 live checks passed; the result is recorded in
`build/plane-check.json`.

Command+Return now runs `open -na Ghostty` in both the default and local
configuration. Two live action invocations each created exactly one new Ghostty
window; only those empty test terminals were closed. The existing Firefox binding
is retained. The local pointer-focus preference is restored; content hover is a
separate app interaction and still requires a physical check after resizing.
Physical four-finger recognition, overview dragging, and magnetic feel remain
unverified by app-targeted automation, which does not enter the global event tap.


## Edge controller follow-up on October 14, 2026

The user reported that content hover still failed after a native edge resize and
that the dragged edge drifted from the pointer. The earlier geometry checks did
not establish physical correctness of that interaction.

Plain edge drags now have one owner from press through release. Tana2D consumes
the entire sequence and requests native size from pointer travel divided by zoom;
it does not also start AppKit's independent native resize loop. The opposite edge
uses the application's accepted size. Requests are coalesced on the existing AX
worker. Release waits for outstanding work; pause/removal cancel management while
still consuming the matching mouse-up. Interior clicks and modified clicks retain
their previous paths. The border explicitly disables mouse events after every
shape change, in addition to its existing ignore-events tag. The private API
returned success on a disposable window on this Mac; physical hover remains a
separate acceptance check. API declaration reference:
https://github.com/NUIKit/CGSInternal/blob/master/CGSWindow.h

`make all test` passed again: 15 native test executables and 20 Python tests.
Production controller tests cover all four edges and all four corners at 25%,
50%, 100%, and 150%; opposite-edge invariance; pointer alignment within raster and
size rounding; minimum dimensions; one undo snapshot; busy-worker release;
interior/modifier exclusions; and pause with a captured press. Logs are in
`build/edge-resize-verified.log`.

Signed packaging and installation succeeded. The temporary border-disable setting
was restored. On restart, macOS reported `sessionUnlocked:false`; Tana2D waits at
its normal startup gate. This prevented a new live harness run and physical hover
or pointer acceptance. The 11 live checks above apply to the preceding build.

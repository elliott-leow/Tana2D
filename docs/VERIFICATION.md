# Tana2D verification

This record covers the separate Tana2D fork. Historical Tana evidence is retained
in [TANA-VERIFICATION.md](TANA-VERIFICATION.md).

## Native presentation override repair — October 14, 2026

Earlier fixture results did not establish native-drag correctness. Terminal and
Firefox accepted base-transform changes while their final compositor transform
and public displayed bounds remained at the native frame. A real CGEvent
native title-bar drag reproduced this even with the manager stopped.

Payload 0.5.2 cleared standard bounds locks. It passed an artificial lock test
but still failed the real native-drag test. It is not a complete repair.
Payload 0.5.3 sets explicit presentation bounds in a WindowServer transaction.
Returning to the native origin and scale clears those bounds and restores the
native base transform, allowing the next native drag or resize to proceed.
Native frame anchors remain unchanged during projection. Provisional transform
placement workarounds were rejected by the never-dragged-window regression.

`make all test live-tools` passes. `live_transform_transaction` verifies the
accepted-base/final-transform discrepancy and twelve corrected projections.
`live_native_projection` verifies scaled presentation before any native drag,
two actual CGEvent title-bar drags, twelve pan/nonuniform zoom targets after each,
and native resets between drags. The local mode passes; the old installed
0.5.2 helper fails the native test. The 0.5.3 app is signed and installed, with
administrator authentication pending for the helper. Foreign-window and full
manager acceptance are pending that replacement.

The border now hides after rejected batches and retries failed creation,
shaping, context acquisition, and ordering. Resize capture now retires a
missing-up predecessor without swallowing the next physical press. Focused
regressions and the full automated suite pass. Live acceptance reads the final
compositor matrix and public bounds, rather than treating a base write as proof.

Atomicity is per helper packet (up to 113 transform records); larger render
batches use multiple packets. This does not establish frame-wide atomicity for
more than 113 simultaneously dirty surfaces. Physical trackpad feel, reboot,
and multi-display behavior are not established by synthetic event tests.

Evidence: `build/terminal-cgevent-before-fix.json`,
`build/presentation-bounds-build-tests.log`, and
`build/presentation-bounds-install.log`.

## Terminal drag and palette crash repair — October 14, 2026

This repair supersedes the installed-build hash and native-drag conclusions in
the earlier audit below. Two crash reports (`tana2d-2026-10-14-191327.ips` and
`tana2d-2026-10-14-191404.ips`) show the same `NSUndefinedKeyException` in
`TanaPalette -filter`. Explicit scored-row extraction replaces recursive array
KVC. The palette open/filter regression passes; the installed palette was also
opened and filtered through its accessibility interface without a crash.

The requested round of 20 concurrent reviewers identified overlapping causes,
which were consolidated before repair:

- Native drag detection no longer waits for the SLS anchor to move. Every sync
  samples the public displayed rectangle, including when the anchor is unchanged.
  The outline uses that exact rectangle. Passive text selection does not capture
  undo, change window layers, snap, or trigger a drop layout.
- Native release retains ownership for the full 150 ms grace period. Missing
  displayed-frame data defers reconciliation instead of restoring stale world
  geometry. Normal title-bar presses in the top-edge band pass through to AppKit.
- Snap candidates must be visible and within a Euclidean screen-distance bound.
  Pointer generations reject competing buttons and expired samples. Pending AX
  resize requests are cancelled before drag ownership; an already issued AX call
  remains uninterruptible.
- Delayed move notifications invalidate transforms. Border style changes redraw
  cached geometry. Failed opacity changes preserve companion visibility. Overview
  and picker ownership no longer overlap. Mission Control entry retires the old
  pointer owner, even if Mission Control consumes its mouse-up.
- A live replay also exposed a zoom interruption defect: stopping an older
  animation after assigning a newer scale could overwrite the new zoom command.
  The old animation is now sampled and stopped before assigning that scale.

The snap bound is explicit: for viewport origin B, zoom s, camera C, and world
point W, define P(W) = round(B + s(W - C)), component by component. A candidate Q
is submitted only when hypot(P(Q).x - P(W).x, P(Q).y - P(W).y) <= 12. Therefore
Tana's accepted snap submission changes the rounded projected origin by at most
12 screen points, including diagonal movement and rounding. Geometry and runtime
regressions cover multiple zoom levels and boundary cases. This is a guarantee
about this acceptance rule, not a guarantee about arbitrary macOS/AppKit moves,
physical input timing, or the absence of all software defects.

Final `make all test` passed, including sanitizer-backed native regressions and
20 Python tests. The signed package and `/Applications/Tana2D.app` executable
both have SHA-256
`7bb00867f8c1235d4f6aead99858f5c81a2cede0c8cbbd7e2591ccb4297e4dc3`;
strict/deep signature verification passed. This exact installed build passed all
20 pointer replay and six snap/release cases described below. The palette was
opened, filtered to `fit`, and closed again without a crash. The released and
panned fixture screenshots were inspected; the outline follows the visible
window. All fixture windows were then closed, the original camera restored,
and all seven user windows retained their exact world geometry. The installed
manager reports `ready:true`, `backend:true`, and `paused:false`.

Logs: `build/terminal-repair-build-test.log`,
`build/terminal-repair-live-pointer.log`, `build/terminal-repair-live-snap.log`.
Reports: `build/pointer-replay-report.json`, `build/snap-release-report.json`,
`build/terminal-repair-installed-state.json`. The new overview gesture regression
was compiled but not exercised through physical desktop input. The controller
replay does not exercise real AppKit title-bar event delivery. A fresh physical
Terminal drag at 100% remains unverified on the repaired build.

## Earlier drag audit and display verification — October 14, 2026

This section supersedes earlier claims that the SLS anchor/matrix alone proves
native title-bar presentation. `CGWindowListCopyWindowInfo` supplies the public
displayed rectangle; native anchors and requested transforms can differ during
AppKit movement. The focus outline follows that displayed rectangle.

The repair separates AppKit title-bar ownership from plane-owned movement,
uses press generations and per-button queue coalescing, recovers native drags
after a disabled event tap, and invalidates transforms after failed helper
batches. Camera, zoom, navigation, and delayed focus actions respect drag/resize
ownership. Owned movement remains exact while held; adjacency snaps on release.

Five rounds used the same ten scoped auditors: snap geometry, native drag,
input queue, selection, renderer, borders, resize, camera/focus, lifecycle, and
verification. The fifth pass reported counts `0,0,0,0,0,0,0,0,1,0`, satisfying
the requested threshold of zero auditors finding more than one defect. The
remaining lifecycle finding concerned clearing the new mouse-owner fields; it
was repaired along with mismatched-button terminal-event handling. This is a
bounded audit result, not a proof that no software defect can exist.

Final source validation: `make all test` passed, including sanitizer-backed
native regressions and 20 Python tests (`build/drag-audit-final-build-test.log`).
The signed package and installed executable match SHA-256
`b4e5f2ed2751133c39516d723049a98c893c2ebef4a820327f9356af47b843ca`;
strict/deep signature verification passed. The final installed build passed all
26 live cases below: 20 pointer replay cases and six snap/release cases
(`build/pointer-replay-report.json`, `build/snap-release-report.json`, and
`build/drag-audit-final-live-{pointer,snap}.log`). Afterward, all fixture windows
were closed, the original camera and zoom were restored, and all seven user
windows retained their exact world geometry. The installed manager reports
`ready:true`, `backend:true`, and `paused:false`.

Live verification scripts:

- `tests/live_pointer_replay.py`: 20 cases across 50%, 70%, 100%, and 200% zoom.
  Normal drag, overview drag, both corner-resize directions, and programmatic
  native-bounds synchronization check public displayed bounds, native sizes,
  actual border bounds, held command guards, and unchanged free release.
- `tests/live_snap_release.py`: six cases across 50%, 100%, and 200% zoom, using
  owned and programmatic-native movement. Held geometry stays unsnapped;
  release yields a 12-world-point adjacent gap. Subsequent camera pan moves the
  displayed window and outline while preserving its world position.
- Both scripts use disposable fixture windows and production controllers. They
  do not post OS input and do not measure physical input-to-photon latency.
  Non-fixture neighbors are checked before treating the replay area as isolated.

The final replay exposed a test-fixture defect: newly allocated synthetic
CGEvents had timestamp zero, so timestamp-based ownership could resolve an older
inactive fixture press and stop automatic native sampling. Fixture events now
receive a monotonic nonzero timestamp; the production sampler remains strict.
The native replay also waits for asynchronous AppKit movement within its existing
500 ms deadline, and always writes an incomplete report after failure.

Full-desktop screenshots `build/snap-released.png` and `build/snap-panned.png`
were inspected: the focused outline matches the window, the adjacent gap is
visible, and the pair moves with the camera. The recorded title-bar automation
attempt produced no event-tap samples and no native movement, including earlier
attempts with the manager paused. Physical AppKit title-bar input therefore
remains unverified; the controller replay must not be presented as proof of it.

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

## Earlier repair status and unresolved behavior

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


## Drag responsiveness follow-up on October 14, 2026

The user reported lag in both title-bar and overview dragging. Both use the same
plane placement function. With a snap target held, that function interpolated the
entire window position, including movement parallel to the snapped edge. It now
animates only a bounded attraction toward the snap; the free axis follows the
current pointer, exact edge crossings cannot overshoot, and leaving the snap
range releases immediately.

The resize feedback change above had also introduced a synchronous WindowServer
bounds read for every tile on every feedback frame. Feedback now uses accepted
native dimensions during translation and measures only pending resizes. Unchanged
visibility no longer opens a compositor batch, external-border discovery waits
until movement stops, and overview dragging keeps the existing screen-bounds
cache valid just like ordinary dragging.

`make all test` passed (15 native executables and 20 Python tests). New production
runtime checks cover movement and reversal along a held edge, immediate escape,
120 stationary frames with zero native bounds queries or compositor batches, and
fresh feedback measurement during a pending resize. Signed installation passed.
The installed build passed all 11 live geometry checks, including four native
resizes and border alignment at full and half zoom (`build/drag-fix-live.log`).

Before the change, the user trial accumulated 322 drag ticks and 311 drag events;
the largest drag tick was 12.949 ms. The broader sample also included a 47.736 ms
frame. These are timing observations, not a controlled speed comparison. The
15-second stack sample missed the user's later drag. The post-install passive
sample contained no drag input, and the live harness validates geometry rather
than physical drag feel; no measured end-to-end latency improvement is claimed.


## Direct movement rewrite on October 14, 2026

The user rejected the preceding drag fix: both lag and snapping remained. That
fix reduced feedback work but left the movement path waiting for a display tick,
wrapped every move in global WindowServer update suppression, and retained edge
attraction. These are separate from the cached-geometry issue.

A disposable-window transport probe compared the same absolute helper transaction
with and without `SLSDisableUpdate` / `SLSReenableUpdate`. Two alternating runs of
180 updates per path measured suppression-path p95 of 5.253 / 4.722 ms and maxima
of 10.611 / 11.863 ms. Atomic transactions alone had p95 of 0.191 / 0.188 ms and
maxima of 0.256 / 0.259 ms. All returned transforms matched the requested position.
This establishes the cost of the unnecessary suppression path on this Mac; it is
not a measurement of physical input-to-photon latency. Reproduce with
`make live-tools && build/live_drag_transaction`. The probe uses only an unordered
disposable window and does not synthesize input.

Both normal and overview drag handlers now submit the latest pointer position
immediately through the same direct placement function. Overview drag events are
coalesced as normal drag events already were. The window and an existing border
are submitted in one atomic helper packet without global update suppression.
All drag magnet/spring logic is removed, and release preserves the pointer-derived
position without a settle animation. Display ticks still support edge camera
panning, but apply camera movement before calculating the held window's position.
An unchanged border does not trigger a second presentation. Helper errors remain
observable and invalidate cached presentation for retry.

The profile now reports `drag_presentations`, `drag_present_avg_ms`, and
`drag_present_max_ms` separately because direct presentations run outside the
frame tick. `make all test` passed (15 native executables and 20 Python tests).
Production tests cover 120 crossings/reversals through former snap zones at four
zooms, exact coordinates before a display tick, one atomic packet per update,
zero global suppression/native moves/AX resizes, immediate overview movement,
and unchanged coordinates on release. The installed build passed all 11 live
geometry checks again (`build/direct-drag-live.log`). The post-install 60-second passive
capture contained no drag input (`build/direct-drag-user-profile.json`), so the
new physical input path and perceived smoothness remain unconfirmed.


## Frozen cursor input corrected on October 14, 2026

The preceding direct-transaction fix did not fix physical dragging. A physical
Ghostty drag was recorded at the event tap. Its global event position advanced
from (684.4805, 62.0156) to (1008.8203, 183.6875), while
`SLSGetCurrentCursorLocation` stopped at (699.2344, 70.6914). The maximum disagreement
was 329.563 display points. Consumed drag events left the cursor query stale;
both movement and owned edge resizing were repeatedly reading that stale value.
Mouse-up formerly recomputed movement using the fresh event coordinate, causing
the apparent catch-up jump. An intermediate change that only preserved the
release position did not restore movement, and the user rejected it.

The event tap now publishes each event's global location before coalescing. Normal
dragging, overview dragging, camera-edge tracking, drag-start detection, and owned
edge resizing read this snapshot. Release commits the last displayed position,
and a release fence prevents delayed drag work from moving it afterwards. Resize
origins use the same pixel rounding during the drag and after release; the live
replay caught a half-pixel difference before this was corrected.

Below 70% zoom, a left click on a managed window is consumed through release and
centers that window at 100%. At 70% and above, normal clicks remain available.
The tap classifies a drag before coalescing, so a delayed drag or a drag returning
to its origin cannot become a center command. Drags preserve zoom. Native manager
panels and unmanaged windows remain outside this automatic selection capture.

The captured coordinates are retained as the content-free fixture
`tests/fixtures/drag_cursor_stall.json`. Production-controller regression tests
replay the frozen-cursor case at 25%, 59.474%, 70%, 100%, and 200% zoom. They check
movement before a display tick, immunity to the stale cursor on later ticks,
release stability, resizing from current event coordinates, and delayed drag/click
classification. Restoring the old cursor query independently to the drag and resize
paths makes these regressions fail (`build/cursor-stall-regression-proof.txt` and
`build/resize-cursor-stall-regression-proof.txt`). The full automated suite passed:
15 native executables, including AddressSanitizer/UndefinedBehaviorSanitizer checks,
and 20 Python tests (`build/pointer-final-tests.log`).

`tests/live_pointer_replay.py` uses the fixture-only `strip fixture-pointer`
diagnostic to replay the event locations through the installed production
controllers and check actual WindowServer geometry. This diagnostic rejects
non-fixture apps and never posts events to the system input stream. It exercises
the controller-to-compositor path, not hardware input-to-photon latency. The
opt-in `strip input-trace-start` / `strip input-trace` diagnostic records only
mouse event coordinates/deltas in an in-memory ring and is disabled by default.

The installed build passed all 16 live replay cases: normal drag, overview drag,
bottom-right resize, and top-left resize at 50%, 70%, 100%, and 200% zoom. Each
case checks 27 motion samples, native sizes, compositor positions, fixed resize
edges, and unchanged geometry at three points after release. World-coordinate
checks allow the documented displayed-origin pixel quantization; release checks
allow only 0.01 point. The fixture's asynchronous native resize must settle within
0.5 seconds for each request. No new movement failures occurred during the run.
Evidence: `build/pointer-replay-report.json`, `build/pointer-replay-live.log`.
The package signature and installed/package binary identity checks passed. The
user was away for these final automated checks; physical feel is not claimed as
user-confirmed, and the code does not establish a universal latency bound.

### Native drag ownership follow-up

The user subsequently reported border-only movement and a Firefox window that
would not move. The preceding fixture replay was insufficient to establish
native title-bar behavior. The native path now forwards the application's entire
drag stream and stops issuing competing window transforms while AppKit owns the
move. Tana follows the actual compositor origin with its model and outline.
Native bounds alone are insufficient: at 70% zoom a fixture's native origin was
(600, 450) while its displayed origin was (572, 361). Saving the native origin
would corrupt the next redraw. The native path now reads the compositor transform.

The production regression covers an independent native anchor at four zooms,
zero competing transforms during a native move, stable release, and a subsequent
forced redraw. Restoring the native-anchor assumption makes it fail
(`build/native-origin-regression-proof.txt`). The full automated suite passed
again (`build/native-owner-final-tests.log`). The installed native AppKit movement
replay passed at 50%, 70%, 100%, and 200% (`build/native-move-live.log`): the
fixture moves its own NSWindow and the production controller observes it; this
does not synthesize a physical drag or establish hardware latency.

At that earlier checkpoint, a broader replay exposed intermittent
camera/geometry differences that were still under investigation. Firefox responded to keyboard focus, but automated title-bar
dragging did not move either Firefox or the disposable fixture, including with
Tana paused. Native input behavior remained unverified; Tana was
paused temporarily to isolate the user's Firefox movement report.


### Presentation bounds and native drag repair (2026-10-14, version 0.5.3)

The preceding native-drag checkpoint is superseded by this repair. A successful
base-transform write did not necessarily change the displayed window after an
AppKit move. The helper now sets explicit presentation bounds in a WindowServer
transaction. Verification compares public displayed bounds with the final
compositor transform, rather than treating the requested base matrix as proof.
Reset clears the presentation bounds before returning a window to native control.

AppKit retains the complete native input stream. If its anchor starts moving
while the displayed surface remains locked, the manager projects the surface and
border from the captured drag coordinates. With no valid captured sample,
including event-tap recovery, native anchor deltas advance the last accepted
position. Body selections with stationary native anchors do not become drags.
The accepted window position, rather than a previous interaction's drag cache,
determines whether another projection is required.

Five challenge reviews covered foreign-window authority, border failures,
replacement presses after a missing mouse-up, packet atomicity, and reset
acknowledgements. Fixes ensure failed border creation/shape/order/transform work
retries, hide a rejected outline, preserve replacement resize capture, and retain
transform ownership until a reset is acknowledged. A live helper test passed with
ordered-out and minimized peers and rejected a stale ID without changing the
other target. Atomicity applies to each packet (at most 113 records), not an
arbitrarily large frame split into multiple packets.

The full `make all test` suite passed after the recovery fix
(`build/presentation-recovery-tests.log`). Live test results below distinguish
controller replay, generated global input, and physical-device acceptance.


Final automated coverage comprises 27 native test executables (including the
production-controller sanitizer regressions) and 20 Python tests. The installed
build passed 16 pointer-replay cases with 27 motion samples each, four
programmatic native-movement cases, and six release-snap cases. Each checks
post-release stability and relevant world, camera, displayed-surface, and border
geometry. Evidence: `build/current-pointer-replay.log`,
`build/current-native-replay.log`, and `build/current-snap-release.log`.
The programmatic fixture mode has no pointer owner: it drives native anchor
observation directly rather than injecting a stationary pointer that competes
with the AppKit move.

With the user's explicit CGEvent authorization, Terminal and Firefox passed
actual global-input native-titlebar drags, release, subsequent pan, zoom, and
public-bounds/final-matrix/border agreement. Terminal also passed a vertical-only
drag with its full-height window. The test records the global input stream and
requires native controller ownership during the move. The repeatable opt-in
entry point is `tests/live_native_app_check.py`; callers supply the target IDs
and known draggable titlebar offsets. Evidence:
`build/native-app-horizontal-check.json` and `build/native-app-check.json`.

These checks establish the measured geometry and generated-input behavior on
this Mac. They do not establish physical trackpad feel, hardware input-to-photon
latency, reboot/login persistence, multi-display behavior, or pixel-level border
appearance. The final build remains installed and enabled.


The final installed-app acceptance run passed all 14 checks with zero additional
movement failures (`build/plane-check.json`, `build/current-plane-check.log`).
Coverage includes signed placement, unbounded camera travel, final transforms,
Option and unmodified overview drags, pinch, fit-all, maximize, and four
AppKit-originated resizes with border checks. Raw contacts now own three-finger
panning; the legacy Dock companion stream is checked for suppression, not used
as a substitute for physical contact input. A prior run passed the geometry
checks but recorded one recovered backend failure; the final run after restart
passed with per-stage failure counters unchanged. No universal latency or
failure-free-under-all-loads claim follows from these measurements.

A software-update authentication dialog obscured the original centered test
coordinates. It was left untouched; the generated-pointer fixture now uses a
clear upper-left area. Final package signature verification and installed/package
binary comparison passed. Test windows were closed and camera/focus restored.


### Adjacent-window docking feedback (2026-10-14, version 0.5.4)

The old collision rule rejected every landing rectangle that overlapped another
window, including existing stacks where docking would reduce the overlap. A
real global-input fixture drag reproduced the missed snap on 0.5.3; the same
scene docks on 0.5.4. The before/after pure-geometry probe also fails/passes
respectively. Windows already stacked with the chosen neighbor do not veto docking from
either approach direction. Separate obstacles still reject new or deeper
overlaps while allowing existing overlaps to shrink. A blocked perpendicular alignment can fall back to a clear
side-to-side landing. No unrelated window is repositioned or resized.

The normal window gap is preserved, and the final movement remains bounded to
12 screen points at every zoom. An engaged neighboring edge retains priority
while it remains eligible; leaving the range releases it. Held windows retain
pointer tracking. The landing outline and bright seam show the exact target
before release, and the release commits that proposal. Engagement requests one
alignment haptic; a successful drop requests a level-change confirmation. Motion
within one target does not repeatedly trigger feedback, and the existing haptics
preference remains respected.

`src/plane_preview.m` owns one reusable, mouse-inert WindowServer surface. It
redraws only for size or docking-edge changes. Translation uses the cached
surface, stationary frames perform no geometry work, alpha writes stop after
fading, and the snap proposal is submitted without a spatial spring or waiting
for the next display tick. Production-renderer tests cover 240 translated frames
without raster/shape changes, 120 stationary frames without movement, click-through
flags, failure retry, and release fading. The four docking-edge raster variants
were rendered and inspected (`build/snap-preview-edges.png`); the interior's
9-percent alpha is asserted. A live hit test through the displayed preview
returned the managed fixture window, not the overlay. CUA's per-app screenshot
excludes separate overlay surfaces, so it was not used as pixel proof of the
composited desktop preview.

Verification completed on the installed build:

- `make all test`: 28 native executables and 20 Python tests passed.
- `tests/live_snap_feedback.py`: all four edges at 50%, 100%, and 200% zoom,
  existing-overlap recovery, and a 120-sample sliding test passed. The actual
  preview bounds match the proposed landing rectangle, engagement occurs once
  per target, release commits once, and the slide adds zero raster redraws or
  haptic engagements. No movement failures were added.
- `tests/live_native_snap_feedback.py`: real global CGEvent title-bar drags
  passed on all four sides, with a presented preview while held, native input
  ownership, and the expected final gap and feedback counters.
- The native overlapping-stack reproduction also passed after installation.

Evidence: `build/snap-feedback-tests.log`, `build/snap-feedback-live.json`,
`build/native-snap-feedback-live.json`, and
`build/native-snap-overlap-before.json` / `build/native-snap-overlap-after.json`.
The 120-sample slide took 1.044 seconds including subprocess/diagnostic overhead;
helper presentation averaged 0.121 ms (0.200 ms maximum), with zero AX resizes.
The maximum measured rendering tick in that run was 8.137 ms. These are measured
software intervals, not input-to-photon measurements or a universal FPS bound.
This session's display link reports 60 Hz. Haptic requests and their gating are
verified; the tactile sensation itself is not instrumented.


A follow-up checked the outside approach explicitly, so docking never requires
overshooting the target's edge. All 14 controller checks and all four actual
native drags passed with `--outside`; the native run also used `--stacked`.
Evidence: `build/snap-feedback-outside-live.json` and
`build/native-snap-feedback-stacked-outside-live.json`.

A second timing run recorded a 23.445 ms rendering tick. Periodic whole-desktop
border discovery was still running inside the held-drag render path; it now
waits until release. Cached companion updates continue normally. A regression
checks 240 held frames with zero desktop enumerations and a refresh after release.
In the final 120-sample repeat, presentation averaged 0.084 ms (0.209 ms maximum),
the renderer's maximum was 1.589 ms, and the complete measured rendering tick
peaked at 1.682 ms. There were zero extra preview rasterizations, haptic
engagements, AX resizes, or movement failures in the slide. The display link still
reports 60 Hz; these software timings do not establish a physical 120 FPS output.
Final package signature and installed/package identity checks passed.


### Zoomed-out hover border (0.5.5)

Reproduced the reported stale border in plane selection: WindowServer hit the
hovered fixture correctly, but `horizontal_hover_allowed` rejected all hover
while `hwm_plane_selecting` was true. Ordinary reduced zoom already allowed hover.
Plane selection now permits the existing focus-without-raise path, which updates
the border without changing the camera or ending click-to-select mode. The
separate native overview retains its own hover handling. Border raster caching
and configured appearance are unchanged.

`make all test` passed, including 20 Python checks. On the installed signed build,
`tests/live_border_hover.py` passed 24 actual CGEvent hover transitions across
three disposable windows at 10%, 25%, 50%, and 100%, in ordinary and selection
modes. Ordinary-mode zoom used generated pinch events. Each check verified focus,
selection-state preservation, unchanged camera, and alignment between the public
window rectangle and the independently measured border surface. Evidence:
`build/border-hover-live.json` and `build/border-hover-final-live.log`.
Installed/package binary identity and code-signature validation passed. These are
injected-input and WindowServer checks, not physical trackpad or screenshot QA.

### Multi-neighbor docking and render cost (0.5.6)

Docking now evaluates simultaneous compatible horizontal and vertical edges,
including a same-size window between two peers and beside a third. It preserves
the 12-screen-point radial limit, the held pointer position, the existing primary
preview seam and haptics, and the window's dimensions. Contacts require overlapping
perpendicular spans at the final landing; large world coordinates cannot inflate
the contact tolerance into a visible gap.
An exact-coordinate cache avoids scoring the same landing repeatedly when
peers are stacked. Its fixed capacity falls back to normal evaluation when full.
The 256-stacked-peer benchmark improved from 314.34 ms to 6.30 ms for ten
proposals; this is a geometry microbenchmark, not a whole-manager speedup.

Rendering changes preserve the existing drawing parameters and target geometry:

- A single helper transform packet uses its existing atomic transaction without
  a redundant global display freeze. Ordinary commands, intermediate flushes,
  capacity splits, visibility changes, and direct surface mutations retain the
  display barrier. The compiled production sender test covers these boundaries
  and a failed overflow send.
- Desktop border enumeration runs on one background worker with immutable
  id/PID publication. The render thread consumes a new result on its next frame
  and validates live ownership before changing a surface.
- Tab member collection uses one traversal; the emitted order, titles, geometry,
  and active state match the former repeated-scan output.
- Border clear and gradient rendering use one transparency-layer composite.
  The production border test compares complete bitmap pixels with the former
  direct renderer across 20 sizes and translucent gradient colors.

`make all test` passes, including 21 Python tests and the new compiled discovery,
feedback, and batching checks. `tests/live_multi_snap.py` passed four actual
CGEvent Option-drag cases: two and three contacts at 100% and 50%. Each verified
the exact landing, unchanged size, visible preview, commit counter, and public
border alignment. These tests do not establish physical haptic feel.
The final duplicate-candidate optimization subsequently passed the full suite
and geometry/runtime checks. Its installed live rerun is pending: the macOS
session became locked, and Tana's startup gate reports `sessionUnlocked:false`.
The final installed/package executable hashes match and the app signature
verifies. This is an installed build, not a verified running session after that
last replacement.

Three trials per stage used twelve disposable windows, the camera/zoom sequence
in `tests/live_performance.py`, and the built-in frame log. Aggregate event-loop
frame timings in ms:

| Stage | Before mean | After mean | Before p95 | After p95 | Before maximum | After maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pan | 5.13 | 4.85 | 8.859 | 9.662 | 24.218 | 26.020 |
| Zoom | 20.25 | 17.32 | 33.065 | 30.813 | 543.163 | 527.582 |
| Focus | 4.80 | 4.62 | 17.340 | 16.553 | 21.680 | 21.670 |

This is a modest measured improvement, not a guarantee of all-frame smoothness.
A prior candidate run had no half-second stall, but the repeat caught one in
border presentation; it remains open. Two helper failures occurred during
fixture setup, before measured stages; the failure counter stayed unchanged
through all nine measured trials and cleanup. Reports are in
`build/perf-before-valid.json`, `build/perf-final.json`, their sample traces, and
`build/multi-snap-live.json`. User window worlds, camera, and focus were restored.
Screenshot inspection failed with ScreenCaptureKit error -3811, so no screenshot
or physical trackpad verification is claimed.

The reported app-content hover mismatch is **not fixed** in this release.
`tests/live_input_projection.m` reproduces the distinction on its own NSPanel:
delivered event-local coordinates follow the transformed surface, while native
cursor polling and screen-to-window conversion use the native frame. Moving
that frame can align the polled point, but asynchronous frame updates introduce
lag, and synchronous AppKit updates clamp negative vertical origins. A prototype
that appeared correct at several positive origins failed the small-scale and
offscreen cases. None of those cursor/frame workarounds is shipped. A reliable
solution still needs presentation and application input coordinates to agree;
the passing border-focus tests above do not prove application-content hover.

### Startup after a long locked session (0.5.7)

The app remained alive overnight in setup, with no manager socket. A process
sample showed `NSApplication run` and `TanaSetup refresh:`; unified logs showed
that setup timer still running. On unlock, every setup requirement was ready,
but the window still required a manual Start click. The cause was the configured
startup path's 120-second unlock deadline, followed by a setup UI that never
automatically accepted the now-ready state.

Configured startup now waits responsively until unlock without a deadline,
then rechecks the existing requirements. Waiting polls only session state;
per-iteration autorelease pools avoid accumulating objects during a long wait.
Explicit setup/preview and missing-permission handling remain unchanged. Unified
logs now identify waiting, unlock, ready startup, and setup fallback.

The setup regression simulates 1,200 half-second polls (ten minutes locked) and
checks immediate passage when already unlocked. The production build, setup
test, eight packaging tests, and signature verification passed. The installed
0.5.7 started directly with `ready:true`, `backend:true`, `paused:false`, preserving
the current camera and window worlds. A physical lock/unlock cycle was not forced
while the user was working.

### Held multi-edge magnets (0.5.8)

Dragging now applies the compatible snap target to the held window before the
surface and border transaction. The unsnapped pointer proposal remains separate
from the presented world position, so leaving the 12-screen-point radius releases
the magnet without accumulating an offset. Native title-bar drags enter this
projection path only after observed window movement; body selections still do
not move or snap a window. Release retains the engaged target and does not score
a second snap from an already magnetized origin.

`make all test` passed, including sanitized held two/three-neighbor contact tests at
0.5x, 1x, and 2x, escape/re-entry, native settle interruption, unavailable native
presentation samples, and the cursor-stall replay with unrelated neighbors moved
out of range. Twenty-one Python checks also passed.

Installed 0.5.8 passed all four focused live two/three-neighbor cases at 0.5x
and 1x (`build/held-snap-live.log`). The broader real-CGEvent matrix passed
28 of 32 cases (`build/multi-snap-matrix.json`). Passing cases include all tested
1x/0.5x native and Option corner approaches, three-peer fits, the staggered
reported arrangement, a partly offscreen surface, fast release, and blocked or
fully offscreen negative cases. It checks the actual held target, final landing,
unchanged size, measured neighbor gaps, independently queried border/preview
bounds, and engagement/commit counters. Synthetic event timestamps are explicitly
nonzero; standard holds dwell 180 ms so the observation loop can see the final
pressed state. The two fast-release cases separately omit that dwell.

The four failures are ordinary native title-bar corner drags at 2x: WindowServer
hit testing identifies the intended fixture and input traces contain the drag
stream, but AppKit does not advance its window. No magnet engages. This remains
an interaction failure, not a passing snap test. The baseline also exhibited
this limitation. The report confirms fixture removal, restored camera/focus,
and unchanged real-window worlds after the matrix.

Application-content hover remains unresolved. The tracked own-panel diagnostic
receives all six events and shows correct delivered local coordinates but wrong
independent cursor queries after translation/scaling. Moving native anchors can
align those queries at selected points; synchronous AX moves clamp negative
vertical origins and asynchronous moves leave a cache delay. An unshipped unit-
scale-only anchor experiment was removed rather than presenting it as a general
solution. A further targeted SkyLight/SDK review found cursor warp/association
and direct-to-process event APIs, but no usable independent cursor-presentation
translation. No cursor warp bridge, app injection, app setting change, or
native-frame workaround is included in 0.5.8. These findings do not establish
that no other OS mechanism exists, and this release does not satisfy the full
requested hover behavior across zoom levels.

The final signed app was reinstalled and reported `ready:true`, `backend:true`,
`paused:false`. Installed and packaged executable SHA-256 both equal
`d26eaf1264f3f2b15a94f3f9812f62a056817d6b508320579f77cadb3a032dc8`.
The repeated matrix on that exact executable again passed 28/32 with the same
four 2x native failures; cleanup restored camera/focus and changed no user-window
world geometry. `build/held-snap-release-tests.log` records the final passing
build/test suite; `build/held-snap-release-matrix.log` records the live failures.
The matrix CLI now exits nonzero on failed cases or failed restoration.

### Native menus and transient focus (0.5.9)

Delayed camera-follow focus now records whether its request was automatic or
explicit. A native menu opening or direct pointer press cancels automatic focus
that was queued before the menu appeared. The flush, gesture-completion, and
follow-target paths also check menu/popup suppression before changing focus.
Keyboard navigation and explicit window selection retain their intent.

The front application's visible custom popups hold focus without an arbitrary
800-point size cutoff. Empty and fully transparent surfaces do not suppress
focus. A negative result is rechecked on the next possible focus change; a
positive result is reused for at most 75 ms. `strip focus-status` exposes the
menu, popup, pointer-hold, and pending-hover state for targeted diagnosis.

`make all test` passed, including the compiled production menu/popup guards and
automatic-versus-explicit queue regressions. The installed 0.5.9 live fixture
passed native root-menu/submenu holding during scroll and a WindowServer-verified
crossing onto another application's fixture. Hover resumed after dismissal.
The separate 1000-by-850 custom popup held focus after the ordinary pointer hold
was explicitly cleared, allowed direct focus to another fixture, and released
hover focus after closing. Its alpha-zero negative case also passed.

The live harness gives generated pointer events the same global cursor position,
clears the existing pointer hold through a real crossing, and remeasures targets
after camera changes. Cleanup disables autofocus while removing its own surfaces
and restores the exact configuration bytes, autofocus mode, user-window worlds,
focus, camera, and cursor. `build/menu-focus-final-pass.json` records the passing
result with all restoration checks true. The strictly verified installed
executable SHA-256 was
`9501864595c1ce86c9d8659359bbc803a5338f36c3a8ceb926ae00e6677766c3`.

This verifies menu focus protection. The application-content hover coordinate
bridge remains an unshipped prototype pending independent cross-window tracking
checks; the remaining 2x native-titlebar cases are not declared fixed here.


### Camera maximum zoom (0.5.10)

The user-facing camera is now capped at 100%. Pinch gestures and named camera
actions clamp at actual size, IPC rejects zoom values above 1, and old saved
state or undo snapshots cannot restore a larger scale. Existing zoom-out and
automatic-fit ranges remain available. Fitting a small focused window keeps
it at actual size and centers it.

The full build/test suite passed, followed by sanitizer-backed geometry and
production undo tests after the final clamp adjustment. The signed installed
0.5.10 reported ready, backend available, and unpaused. Live commands for
1.001, 2, and 4 were rejected without moving the camera.
`tests/live_zoom_cap.py` passed four generated-input checks: a large positive
pinch stopped at 100%, further positive pinches kept the camera fixed, a
negative pinch zoomed out, and focused-window fit stayed at 100% with correct
centering. `build/zoom-cap-live.json` records the samples and restored user
geometry/camera.

The prior four 2x native-titlebar cases are outside the supported zoom range
after this explicit user-requested cap. They are replaced with 25% cases in
the current matrix; this does not claim their former behavior was repaired.

The updated installed-app snap matrix passed all 32 supported cases, including
held and released two-/three-neighbor contacts, native/Option drags, all four
25% native corners, fast release, blocked landing, partial-screen placement,
and offscreen-peer rejection. Each case checked unchanged dimensions and
independent presentation bounds; cleanup removed fixtures, restored focus and
camera, and changed no user-window world geometry. The report is
`build/multi-snap-matrix.json` (version 0.5.10).

> Historical Tana measurements. Re-run benchmarks and live measurements before making Tana2D performance claims.

# Performance and animation verification

The optimization constraint is unchanged behavior: keep the dynamic strip,
animations, live overview content, geometry, gestures, stacking, and recovery.
No frame-rate limit, shorter animation, static screenshot, or removal of visual
effects was used as a speedup.

## Measured CPU work

Run `make bench` on macOS with the Xcode command-line tools. The benchmark uses
an optimized build and reports the median of five runs. These measurements
compare CPU routines, not end-to-end latency or compositor frame delivery.

Measured on the development Mac on 2026-10-12:

| Workload | Reference | Optimized | Ratio |
| --- | ---: | ---: | ---: |
| 300,000 standard easing evaluations | 91.358 ms | 1.531 ms | 59.67× |
| 16 independent columns, repeated layouts | 5.943 ms | 2.752 ms | 2.16× |
| 64 independent columns, repeated layouts | 18.030 ms | 2.820 ms | 6.39× |
| 256 independent columns, repeated layouts | 74.001 ms | 3.183 ms | 23.25× |
| 1,024 independent columns, repeated layouts | 257.158 ms | 3.118 ms | 82.48× |

Layout workloads process approximately 200,000 items in total per run. The large
counts are scaling tests, not a claim about typical desktop window counts.
Small strips retain the simpler allocation-free layout. The indexed layout
includes allocation cost in the timing and falls back if allocation fails.

The fixed easing curve uses bounded Newton inversion instead of 56 bisection
steps. Its output matches the reference within 1e-12 in dense and randomized
checks. Arbitrary curves retain the general evaluator. Indexed layout matches
the scan implementation exactly across randomized columns, interleaved rows,
invalid weights, extreme dimensions, and invalid identities.

Small helper writes now attempt the nonblocking send before polling. The
transport regression verifies zero readiness polls on a writable socket and
bounded timeout under backpressure, alongside partial reads, EOF/ACK, fragmented
handshakes, and descriptor cleanup.

## Review passes

1. **Math and transport:** optimized fixed-curve inversion, indexed larger
   column layouts, and removed the redundant writable-socket readiness poll.
2. **Animation and repeated work:** added the missing interactive transitions;
   eliminated duplicate display-bound reads within layout/preview operations,
   redundant enhanced-UI guards around AX frame calls, and preview path/region
   allocation when only opacity is changing.
3. **Dynamic scrolling:** corrected movement-notification invalidation that
   turned pans into resizes; preserved each window's last submitted viewport
   offset when retargeting; grouped pan moves for compositor submission. The
   production renderer passes 80 simulated gesture frames with delayed
   notifications and zero AX resize calls. The user confirmed smooth physical
   scrolling on the installed correction.
4. **Final review:** checked rendering, retargeting, gestures, reconciliation,
   overview, transport, persistence, and rename compatibility. No further
   actionable speedup was found that had evidence of benefit while preserving
   the current behavior. This is a bounded review result, not a proof that the
   application cannot be optimized further.

## Evidence and remaining limits

`make test` includes the production layout, renderer, floating transitions, and
close behavior against deterministic OS stubs under ASan/UBSan. It covers dynamic
stack changes, late movement notifications, resize reversals, new windows,
helper failure, canceled transitions, and refused closes.

`tests/live_animation_check.py` observed five intermediate WindowServer frames
for each fixture float/fill/restore/retile transition and exact restoration.
`tests/live_overview_check.py` passed transform, grid, border, and cancellation
checks. Physical scrolling was confirmed by the user. Screenshot inspection of
the new overview highlight was blocked by a local ScreenCaptureKit error.

Accessibility sizing remains application-dependent and can stall the serialized
renderer; CPU microbenchmarks do not remove that platform constraint. The
manager releases compositor suppression before any AX sizing call. Performance
with unresponsive applications, multiple displays, wake, and Dock restart still
requires separate live acceptance testing.

## Frame pacing pass (2026-10-12)

The earlier passes measured how long a frame takes to compute. That number was
already small and did not explain a swipe that sometimes lagged, so this pass
measured pacing instead: when frames are drawn, what delays them, and how
evenly the strip advances. `strip pacing` reports tick latency, dropped frames
and the cost of every event-loop handler; `strip frame-log` returns the camera
position of recent frames next to the swipe reports that drove them. Each frame
is `[time, x, tick ms, latency ms, y, zoom]`; the last two show pinch pacing.
`pacing-reset` clears both.

All figures are from the development Mac (60 Hz built-in display) with the
user's own windows, driven by synthetic three-finger swipes posted as Dock
gesture events with accurate timestamps. Physical swipes were not measured.

| Finding | Before | After |
| --- | --- | --- |
| Per-frame step of a steady held swipe, standard deviation over mean, reports every 11 ms | 0.33 | 0.10 |
| Same, reports every 13.5 ms | 0.34 | 0.10 |
| Housekeeping sweep on the frame thread during a swipe | 2 to 3 ms, ten times a second, up to 10 ms | does not run while frames are drawn |
| Housekeeping sweep with the desktop at rest | about 3% of one core | twice a second |
| Frame thread scheduling priority | 31 (default) | 46 (user-interactive) |
| Stall when focus follows a swipe | 8 to 16 ms | 5 to 9 ms |
| Overview opening, frames over 8 ms of about 310 | 40 to 58 | 1 to 11 |

What changed:

- **Held swipes are drawn where the fingers are at the frame.** Finger reports
  and display refreshes are not in step, so a frame followed one report, two,
  or none, and a steady swipe advanced 16, 48, 16, 48 points. Each frame now
  carries the strip on from a line fitted through the last 50 ms of reports,
  for at most 12 ms past the newest. Speeds are measured between the reports'
  own timestamps rather than the times this process got to them. The overview
  gesture is resampled the same way.
- **The frame thread runs at user-interactive priority** and the process opts
  out of App Nap.
- **Helper commands of a frame are handed over together and awaited once.**
  Eight sequential moves cost a median 0.82 ms against the live helper; the
  same eight pipelined cost 0.38 ms. An overview frame sends two per card.
- **The housekeeping sweep waits while frames are drawn**, runs at 10 Hz for a
  second afterwards (when a correction can be needed) and at 2 Hz at rest.
  WindowServer already reports ordering changes as they happen.
- **Blocking Accessibility round trips left the frame thread.** A window's
  title is fetched when something asks for it, not on every title change, and
  an activation Tana requested no longer asks the application which window it
  focused.
- **The usable-screen rectangle is cached** until the display, Dock or menu bar
  reports a change, and is never refreshed mid-swipe.
- **Saving the layout writes on its own queue**, not at the end of every glide.
- **The overview's scrim is faded by the helper on its own clock.** Setting the
  blurred window's opacity from this process every frame, to follow the
  fingers, was the cause of nearly all slow overview frames: with the scrim
  disabled the same test showed none. The scrim now fades in once when the
  overview opens and out when it closes; it no longer tracks the fingers.
  The outline and captions are drawn at the cards' resting places and shown as
  the cards arrive, instead of being redrawn under every frame of the flight.
- **Opening the overview no longer waits for the main thread** to raise the
  overlay, and the overlay's windows are built at startup.
- **The frame clock stops while a native fullscreen Space is in front**, and
  the idle fallback timer runs at 10 Hz instead of 60 Hz.

Not improved: each card of the overview still costs two helper commands per
frame, each of which is three WindowServer round trips inside Dock. Removing
that needs a new helper opcode and a reinstall of the scripting addition.

## Border, hover and sweep pass (2026-10-18)

Measured on the development Mac (60 Hz) with `tests/live_performance.py` and a
fixture variant whose twelve windows all differ in size, plus a scripted sweep
of the pointer across nine visible fixture windows at 120 Hz (three runs each).
Physical trackpad and mouse input were not measured.

| Finding | Before | After |
| --- | --- | --- |
| Slowest frame when focus moves between equal-size windows | 35 to 38 ms | 0.3 to 0.4 ms |
| Border work on the frame thread when focus moves to a new size | 7 ms paint plus a ~30 ms update-suspended, synchronous helper batch | 0.02 to 2 ms; the paint (25 to 140 ms of WindowServer waits) runs on its own queue |
| Pointer-move handling during a fast sweep, mean per event | 2.6 to 4.5 ms | 0.8 ms (after the first sweep) |
| Event-loop stalls over 2 ms per sweep | 144 to 184 | 16 to 23 (after the first sweep) |
| Settled-window bounds check in the housekeeping sweep, 28 windows | 6.8 ms (two round trips each) | one 0.5 ms query plus the order check |

What changed:

- **The outline is a cache of rings.** Three rings of four strip surfaces are
  kept, each drawn for one size; focus returning to a size already drawn
  paints nothing. A new size is painted on a background queue into a ring
  that is not on screen, while the ring on screen is stretched to the new
  window as it already was through a zoom. Finishing a paint waits for
  WindowServer to take the surface (`SLSConnectionSynchronizeSLSCATransaction`
  under `CGContextEndTransparencyLayer`), which is what made focus changes and
  fast hovering drop frames.
- **Rings swap by alpha inside the frame's helper transaction** when the
  helper supports it (0.5.7). Before, a repaint suspended screen updates and
  waited for the helper's reply. Older helpers keep the ordered swap.
  `strip profile` reports `border_atomic`.
- **The popup focus guard reads on-screen windows with one batched query**
  instead of a description dictionary per window, and keeps a negative answer
  for one frame. It ran on most pointer moves that crossed into another window.
- **The housekeeping sweep reads settled windows' bounds in one query**; the
  batched bounds equal `SLSGetWindowBounds` for transformed windows too.

The first sweep after a restart still shows the old pointer-move cost while
caches and surfaces warm up. With JankyBorders (`borders`) running, Tana2D
enumerates the whole window list every half second to keep its outlines
hidden; on the development Mac `borders` has since been stopped and removed
from login.

## Pinch, multi-app hover and drag pass (2026-10-18)

Same machine and method. The pinch was replayed as 120 Hz magnification
events; hover swept the pointer across twelve fixture windows owned by four
different applications; drags were held title-bar drags at 100%.

| Finding | Before | After |
| --- | --- | --- |
| First frames of a pinch out of 100% | jumped ~7% past the fingers, then stood still for 2-5 frames (frame gaps up to 90 ms) | follows the fingers from the first frame |
| Application switch while hover crosses apps, per switch | 7 to 10 ms | 0.05 to 0.2 ms |
| Window-focused handling per hover handoff | 1.7 to 2.7 ms | 0.02 to 0.4 ms |
| Dropped frames per multi-app sweep | 7 to 22 | 0 to 1 |
| Frame tick during a 100% title-bar drag, mean | 5.6 ms | 1.5 to 2.9 ms |
| Tana2D CPU at rest | | 0.5% of a core |

What changed:

- **A gesture's speed is read from three reports spread over 20 ms.** The
  first reports of a pinch or swipe often arrive within a millisecond of each
  other; a line through two of them read as a huge speed, so the first frame
  was drawn far ahead and the next ones waited for the fingers to catch up.
  Pinch sensitivity is now `pinchGain` (default 1.35).
- **Popup guard over our own WindowServer connection.** The public
  on-screen window list looked up the server's port on every call.
- **Focus handoffs Tana2D asked for skip the "did the old window close?"
  round trip**, and a window's layer is not set again within two seconds of
  setting it, which waited for Dock's reply on every focus change.
- **Displayed frames come from one batched query** (`SLSWindowIteratorGet-
  ScreenRect`, equal to CGWindowList's bounds for transformed windows), and a
  drag reads native and displayed bounds together.
- **At 100%, native placement reads every window's bounds once per frame**
  rather than up to three times; a settled window already in place is not
  measured again.
- **Smaller ones:** the visible-Space check is cached until a Space or
  display change; the hidden camera panel is not relabelled on every percent
  of a pinch; the Dock badge poll asks LaunchServices about each process once.

## Focus intent, overlay, helper and drag pass (2026-10-19)

Same machine. CPU is summed over every process during the run; hover used
four fixture applications; the helper is 0.5.8.

| Finding | Before | After |
| --- | --- | --- |
| Application switches, fast sweep across 12 windows (3 s) | 24 to 25 | 0 to 5 |
| Application switches, quick back-and-forth between two windows (3 s) | 20 | 1 to 2 |
| WindowServer during that sweep | 68 to 70% | 17 to 30% |
| BiomeAgent / WindowManager / MenuBarAgent during it | 29% / 21% / 15% | 5% / under 5% / 5% |
| Pointer parked on a window until it has focus | immediate | 16 to 22 ms median, 47 ms worst |
| Frame tick during a 100% title-bar drag, worst | 25 to 35 ms (first drag after launch up to 500 ms once) | 11 to 18 ms, no dropped frames |

What changed:

- **Hover focus follows intent** (`hwm_focus_intent_sample`). Every focus
  change activates an application, and macOS reacts system-wide: both
  windows redraw, WindowServer and Dock switch the front application, and
  the menu bar, usage logging and window services all run. Focus now moves
  once the pointer slows below 450 points a second over a window (speed
  along its path, so a reversal is not mistaken for a stop), stops (looked
  at again 40 ms after the last movement), or stays 0.8 s; and at most once
  every 150 ms. Pending focus (camera rest, landing windows) waits the same way.
- **The feedback overlay leaves the screen when it shows nothing.** It is a
  full-screen panel above every window; ordered in while empty it cost a
  full-screen composite whenever anything beneath redrew.
- **The snap preview paints off the frame thread** into the one of two
  surfaces not on screen, like the outline.
- **The helper reads every record's native bounds in one query** (0.5.8)
  instead of one synchronous request per moving window per frame.
- **At 100% a drag no longer waits for Dock's reply every frame**: only the
  renderer's own projections are settled before native placement. A drag's
  frame does not sample the surface again right after its pointer event did.
- **Pinch:** the lead is dropped within a frame when the fingers lift.
- **JankyBorders discovery** reads only on-screen windows of the `borders`
  process, in one query.

Checked and left alone: windows parked off screen by a transform report
themselves occluded to their applications (so they throttle); Tana2D's
outline made no measurable difference to WindowServer (42.7% with it on or
off); panning at 100% with native placement cost the same as at 60%.
WindowServer's remaining load at rest comes from the applications on screen.

## Pan and pinch under load (2026-10-19)

Read from the code and the live counters of the installed build (`strip
pacing` and `strip profile` after an ordinary session); nothing here was
measured under a loaded CPU, which is where the user feels it. The counters
showed the batch release, the hand-over of a frame to Dock's helper, peaking
at 18.8 ms, and the housekeeping event running ten times a second on the
frame thread throughout a gesture, each time waiting for Dock's reply first.

What changed:

- **A frame no longer waits for Dock to acknowledge the previous one.** The
  tick settled on the previous frame's reply before it began, so every frame
  was tied to when Dock's helper thread got the CPU; under load that wait was
  most of a refresh and the tick missed its vsync. Two frames may now be
  awaiting their reply at once; replies that have arrived are read without
  waiting (`hwm_sa_ready`). With two outstanding the next frame is not queued
  up behind them: its records are carried into the following frame, a newer
  record for a window replacing the carried one, so when the helper catches
  up it applies where the windows are now rather than a backlog. Anything
  that reads geometry (`scripting_addition_settle`, `hwm_batch_settle`, any
  ordinary command) still waits for every reply and applies carried records
  first. `tests/test_sa_batch_barrier.py` covers the in-flight limit, the
  carry and merge, and a refused frame surfacing at the next end.
- **Ticks of a held pan or pinch do not settle at all**, unless something is
  pointer-owned (a drag, a resize, an edge); the renderer settles itself at
  the two places a frame reads geometry, an application's own move or
  resize. The housekeeping sweep settles only once it has decided to ask
  WindowServer anything, and a title change, which reads no geometry, never
  does.
- **The prediction horizon follows the display.** A frame is shown at the
  vsync the clock named, a whole refresh after the tick. The fixed 12 ms
  horizon covered that on a 120 Hz panel but left a 60 Hz panel's frames
  drawn for a moment 5 to 10 ms before they appeared, so the strip trailed
  the fingers by that much. The horizon is now one refresh plus 4 ms, between
  12 and 22 ms (`hwm_held_lead_max`), for the pan, the pinch and the overview
  gesture alike.
- **Dock's helper thread runs at user-interactive priority** (helper 0.5.9).
  It applies every frame, and at the default priority a busy CPU ran it
  late with the frames queued behind it. The multitouch callback thread,
  which delivers every pan report, is raised the same way: at the default
  priority its reports arrived late and bunched, which the pan's speed
  estimate read as steps.

Not changed: each frame still opens a new connection to the helper; the
connect itself does not wait for the helper, so a persistent connection
would save only the accept wake-up.

## Pinch from the contacts (2026-10-19)

The pinch no longer comes from the system's gesture recogniser. That
recogniser reports a magnify only when the two fingers move against each
other; a natural pinch, with the thumb resting or both fingers drifting the
same way as they part, it reported as a scroll, and the plane did not zoom.
The zoom is now the change in the two fingers' separation, read from the raw
contacts the three-finger pan already uses (`plane_pinch.h`), which a shared
drift does not touch. A pair is undecided until its separation has changed
by about 2 mm with little shared travel, or by about 3 mm while still at
least a third of that travel; it then zooms, catching up on the change so
far. A pair that travels 3 mm with its separation steady is a scroll until
it lifts. While the contacts zoom, the recogniser's scroll stream for the
same fingers (and its momentum) is dropped, and its magnify events are
ignored while two fingers are down; a replayed magnify with no fingers down
still zooms, so the live tests are unchanged. Pinch reports now reach the
loop at the trackpad's report rate with the device clock mapped as the pan's
is, rather than through the recogniser's start-up hysteresis.

## WindowServer pass (2026-10-19)

The question this pass answered: why WindowServer sits at 30-40% while the
plane pans, and what would bring it under 5%. Measured on the development
Mac (M5, macOS 27.2 beta, 2560x1664 panel in the 1710x1112 scaled mode,
60 Hz) with `top` sampling WindowServer once a second, pans driven as
`strip pan` glides every 0.27 s, and a standalone microbenchmark
(`wsbench`, not part of the tree) that creates its own CGS windows and sends
one WindowServer operation per window per frame. Samples taken while the
display was asleep read 1-3% for everything and were discarded; the display
sleeps after about twenty idle minutes and the lock is immediate, so a
measuring session needs `caffeinate -d`.

| Scenario, display on | WindowServer |
| --- | ---: |
| Camera on an empty plane region, nothing moving | 1% |
| 12 fixture windows on screen at rest, any zoom | 2% |
| One 400x300 CGS window moved per frame, nothing else on screen | 16-21% |
| One screen-sized window moved per frame | 24% |
| 12 windows moved per frame: move, transform or locked bounds, shadows on or off | 22-30% |
| One window repainting at 10 Hz, no motion | 7% |
| One window repainting at 60 Hz, no motion | 18% |
| Tana2D pan, 12 fixtures, 100% (native-ride records) | 22% |
| Tana2D pan, 12 fixtures, 70% (locked-bounds records) | 22-28% |
| Tana2D pan, the user's real windows, 100%, 90% and 56% | 22-27% |
| The user's real windows at rest, any one of them alone on screen | 10-12% |

What it means:

- **The cost is per composited frame, not per window.** WindowServer spends
  3-6 ms of CPU on every frame in which anything on screen changed. At 60
  frames a second that is 16-24% before the plane moves a single window, and
  the same whether one tiny window or twelve move. Shadows, the choice of
  move versus transform versus locked bounds, the three operations the
  native-ride record sends, and zoom scale made no measurable difference.
- **Each additional window moved per frame adds about 0.55%.** A pan of
  three visible windows plus the four strips of the focus ring costs some 4%
  on top of the floor.
- **The floor is a property of this Mac and OS, not of Tana2D.** Reduce
  Transparency changed nothing (18.6% against 19.3%). Stopping sketchybar
  and its 17 bar windows changed nothing (16.2% against 16.4%). The native
  1280x832 (2x) display mode was worse, 30% for one moving window; Apple's
  default 1470x956 scaled mode read 21%; the 1710x1112 mode in use is the
  cheapest of the three.
- **Rest costs come from the applications.** Twelve static fixture windows
  cost nothing at rest; any one of the user's real windows alone on screen
  held WindowServer at 10-12%, which is the compositor following that
  application's own repaints or CoreAnimation animations. Earlier in the
  session, with a terminal animating a spinner and all five windows visible
  zoomed out, rest read 37%.

Consequences for the 5% target: at 60 frames a second the compositor floor
alone is three to four times that figure, so no change inside Tana2D can
bring a pan under 5% on this machine. What the pass changed is the one
WindowServer round trip per frame that could go: a frame of native moves and
alphas (a pan at 100%) no longer asks WindowServer for every window's bounds
first (helper 0.5.10); only scaled records need the native size. Folding the
focus ring's four strips into one surface would save another 1.5% but
reintroduces the window-sized repaint and reshape cost that the strips were
introduced to avoid, and was not done.

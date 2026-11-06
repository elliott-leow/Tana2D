# Gesture ownership and smoothness

Tana2D remains usable with one hand on the trackpad. Choose **Show workspace**
in its menu. Two-finger scrolling and background dragging pan, pinching zooms,
window dragging rearranges, and side/bottom edges resize. Click a window to
enter it at 100%; right-click returns to the focused window. The hand icon and
menu checkmark indicate workspace mode. Unbound typing exits this mode.

Bare three-finger panning and workspace pinch are the one-handed default.
`settings.gestureActivation: "fn"` optionally requires Fn outside workspace
mode. Ordinary scrolling and rotations stay native. This default was restored
after the user reported that Fn impaired one-handed use; the live app was
reloaded without another pan-algorithm change and the user reported improvement. Fn-drag replaces the old Option-drag default so apps keep
Option-copy/selection. Custom keyboard overrides remain intact; defaults use
Control+Option+Command. The example config and onboarding use these defaults.

Contacts keep their first owner until full lift. Fn pressed midway through an
app gesture cannot steal it; releasing Fn cancels motion without allowing the
same contacts to restart. Mouse activity fences queued contact reports. Scroll
streams retain their owner through momentum. Modified low-zoom clicks stay
native. Palette clicks commit on release; dragging away cancels them.

## Three-finger panning at 100%

The user identified this as the motion that feels less smooth than macOS.
The following code defects were corrected:

- The old predictor stored only six reports and required 20 ms of history.
  Above 250 Hz, that history is always too short to enable prediction.
- Its prediction horizon was capped around 20.7 ms at 60 Hz, which can be too
  short for a future display target plus the age of the latest input report.
  Different report/display phases can therefore produce uneven steps even at
  constant finger velocity.
- A regression intercept could shift the displayed position away from the
  newest actual position, especially during acceleration or reversal.
- Improving the raw touch clock's estimated delay could move mapped report
  time backward, discarding pan motion. Device clocks also shared one mapping.

Panning now uses a 64-report, time-bounded predictor anchored to the latest
actual camera position. Prediction requires 12 ms and at least three reports,
resets on substantial reversals, stops on an axis when its latest delta stops,
and holds stale input. Its horizon includes a refresh plus two report intervals
(up to 50 ms). Touch clock mappings are per device and monotonic. A small pan
intent threshold rejects resting drift while preserving initial movement.

Sanitized tests cover 80/125/240/300/500 Hz reports with 60/120 Hz frames,
future vsync targets, bunched startup, large coordinates, direction changes,
stationary/stale/reordered reports and sideways sensor noise. These establish
algorithm behavior, not the feel of a physical gesture.

## Current measurements and remaining limits

Before the predictor replacement, synthetic camera glides over the real
managed desktop produced these results on the 60 Hz display:

| Scale | Client frames | Largest tick | Client drops | Helper-held frames |
|---|---:|---:|---:|---:|
| 100% | 193 | 0.314 ms | 0 | 0 |
| 70% | 193 | 0.794 ms | 0 | 0 |

Median WindowServer geometry-change intervals in a separate sampled run were
16.53 ms and 16.57 ms. That run included longer geometry plateaus; pixel/point
quantization and spring tails can repeat coordinates without missing a client
frame. Geometry polling adds overhead and does not measure display scanout.
The camera was restored and world frames were preserved.

This rules out a persistent low client frame rate in those synthetic trials.
It does not reproduce the physical three-finger path or prove a particular
bottleneck caused the reported feel. Focus/order handlers reached 4–6 ms during
one zoomed-out trial. These share the event loop with frames. At other loads,
helper backpressure may hold frames, and scaled records still query native
bounds in the helper before committing. Neither was demonstrated as the cause
of this user's native-size swipe.

`strip transport` / `transport-reset` now expose sent packets, held updates,
collected replies and time spent waiting for ACKs. ACKs mean the helper
submitted a transaction, not that the display presented it. Frame computation,
helper handoff, WindowServer geometry and actual display presentation must
remain distinct measurements.

To record the physical input path after installation:

```
python3 scripts/capture-gesture-pacing.py
```

This records six seconds of normal user gestures and changes only diagnostic
counters. It injects no input and does not change the camera. Physical
trackpad acceptance and a matched Mission Control presentation trace remain
open. Apple's render-loop guidance explains why even short deadline misses
can hitch despite a nominal 60 Hz clock:
https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app

## Follow-up from physical use

The first physical trace (build/lag-report-frame-log.json) has 534 raw camera
samples, predominantly 8 ms apart. Frame cadence during the swipe is mostly
16.67 ms. Aligning camera curves suggests 160–190 ms between logged device
sample time and rendered motion. This cannot establish real latency because
it lacks callback-arrival times and handler times. Tick queue latency measures
a different queue entry. `frame-log.touch_timing` now supplies aligned triples
`[mapped_device_time, callback_arrival_time, handler_time]` for each input row,
so stale clock mapping and actual input queue delay can be separated. The user
reported improvement after bare gestures were restored; no further predictor
change was made in that follow-up.

## Click intent with interaction history

The camera predictor is unchanged in this pass. Click intent uses deliberate
activity and navigation; hover focus alone never establishes intent.

| Context outside explicit workspace mode | Result |
|---|---|
| Plain body click after a pan/pinch | Select and zoom to 100%, even above 50% |
| Continuing to work in the same window | Deliver the click to the app |
| Switching to another window while zoomed out | Select and zoom |
| Native content scroll, typing, completed modified click | Record deliberate app interaction, ending prior browsing intent |
| Explicit keyboard/app activation | Record interaction; hover activation is excluded |
| No recent history at intermediate zoom | Preserve native click |
| Far-view plain body click | Retain click-to-enter cutoff behavior |
| Title bar or traffic-light region | Preserve native window behavior |
| Resize edge/corner | Preserve resize ownership |
| Command/Control/Option/Shift click | Preserve native modified click and record its completed interaction |
| Click turns into a drag | Move instead of zooming |
| Release over another window | Cancel selection |
| Rapid repeated click during focus landing | Consume the tail so it cannot accidentally activate content during motion |
| Old browsing history or lifecycle cancellation | Expire/reset context |

History expires after 30 seconds. Window-body controls are not semantically
classified with synchronous Accessibility calls: that would block the global
input tap. A body click during browsing is intentionally a window-selection
request; recent app activity makes body clicks native. The explicit **Show
workspace** mode continues to treat windows as selectable/draggable cards.

Validation includes the pure policy plus integration with the production
center-click hit tester and native geometry. This verifies routing cases;
subjective intent matching still requires physical use.

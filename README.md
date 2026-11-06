# Tana2D

A macOS window manager with an unbounded two-dimensional workspace. Derived from
[Tana](https://github.com/elliott-leow/Tana), developed as a separate project.

Experimental. See the [verification record](docs/VERIFICATION.md) for tested
behavior and remaining limits.

Choose **Show workspace** from the Tana2D menu to browse with one hand: scroll
with two fingers or drag the background to pan, pinch to zoom, and click a
window to enter it. Three-finger panning and pinching also work directly,
without holding a key. Fn/🌐 activation is available as an opt-in setting.

While browsing, pinch to zoom, swipe to pan. The pinch is read from the fingers' separation,
so the thumb may rest or both fingers drift while they part; the fingers need
not move against each other. A pair of fingers zooms once its spread has
matched its shared travel for a few hundredths of a second, both overall and
in the latest motion, so a scroll whose fingers set off one before the other
is still a scroll; a pair decided a scroll stays one until it lifts, so a
scroll in an application never turns into a zoom part-way. Clicks and drags
(including screenshot selections) exclude their contacts from zoom until
every finger lifts; rotations also stay separate from pinch zoom. A pinch the
system's own recogniser reports zooms at once. Zoom stays anchored at the pointer all the way
back to **100%** and preserves every window's size. A pinch toward 100% that
comes to rest at 90% or more finishes the zoom to exactly 100% about the same
point. There are no workspace walls. A pinch zooms out until every window
fits on screen (or to 20%, whichever is further) and no further, and it comes
to rest exactly where the fingers stopped.

Clicks use recent deliberate interactions rather than hover focus alone.
After panning or pinching out, a plain click on a window's body focuses it
and returns it to 100%. A click while continuing work in the same app stays
native; native scrolling, typing, modified clicks, and explicit app activation
establish that history. Switching to another window while zoomed out selects
it. Unknown or expired history preserves native clicks above the far-view
cutoff (`"zoomClickThreshold"`, default 0.5); below it, plain body clicks select.
Title bars, native window controls and resize edges retain their own behavior
outside explicit workspace mode. Selection commits on release; dragging application content keeps its native
drag behavior instead. Recent interaction history expires after 30 seconds.

Zoom never remaps the pointer or
changes display configuration. At 100%, once the camera rests, every visible
window's own frame matches where it is drawn, wherever it sits on screen, so
hover and clicks land where the pointer is. Some applications track hover by
polling the cursor position themselves (Firefox, for example). Their in-app
hover effects, and menus they open at the pointer, can appear offset while
zoomed out, and at 100% in a window whose title bar is above the menu bar:
macOS will not let an application's frame go there, so its own record stays
below the menu bar while the window is drawn higher.

Hover focuses the window the pointer settles on: once it slows over a window
or stops (within a few hundredths of a second), not every window a quick
sweep passes over, and at most every 150 ms. Each focus change makes macOS
switch the front application, which costs every process involved. At 100%,
hover focus never changes zoom or moves the camera. Hover never steers the camera: while it moves, hovering does nothing,
and the window under the pointer is focused once the camera rests. All windows
move together in one compositor transaction per frame, and windows above the
top edge stay visible. Native windows keep accepting clicks during panning.

There is no on-screen camera panel. Use the gestures and shortcuts below, the
menu, or the command palette.

## Install

```sh
make all test
./scripts/install.sh
```

The installer builds and installs `/Applications/Tana2D.app`. Open it, grant its
own Accessibility permission, and set up its bundled window helper. Quit other
window managers before starting it. The setup page checks these requirements.

Full operation requires the helper's existing macOS security prerequisites.
See [installation and setup](docs/INSTALL.md). Supported configuration is one
connected display on macOS 14 or later. Real gesture feel and login persistence
require testing on the target Mac.

## Controls

| Input | Action |
| --- | --- |
| Tana2D menu → Show workspace | Enter one-handed workspace browsing; choose again to return |
| Two-finger scroll or background drag in workspace mode | Pan in any direction |
| Click a window in workspace mode | Enter the window at 100% and resume native app gestures |
| Right-click in workspace mode | Return to the focused window and resume native app gestures |
| F11 (Fn + F11 on a laptop) | Enter or leave native fullscreen for the focused window |
| Control + Option + Command + M | Reset zoom to 100% and resize the active window to fill the usable screen |
| Three-finger swipe | Browse the workspace in any direction, including diagonals |
| Pinch | Zoom out or return up to 100% |
| Control + Option + Command + Return (or S) | Zoom out to the whole workspace; press again to return to the focused window at 100% |
| Four-finger swipe down | Center the active window at 100% without resizing it |
| Four-finger swipe up | Open the same click-to-center mode |
| Control + Option + Command + T | Open a new Ghostty window |
| Control + Option + Command + B | Open Firefox |
| Control + Option + Command + arrow | Focus the nearest window in that direction |
| Control + Shift + Option + Command + arrow | Move the focused window one grid step |
| Click a window after panning or pinching out | Focus it and zoom to 100%; body drags stay with the app |
| Drag a title bar, or Fn-drag a window | Follow the pointer; dock beside nearby windows, with a blue bar in the gap for every docked edge |
| Deliberately overlap another window and pause briefly | Preview two side-by-side halves; release to accept, move away or Escape to cancel |
| Hold Command while dragging | Place the window freely, without docking |
| Drag a window edge or corner | Resize in plane coordinates, preserving the opposite edge |
| Control + Option + Command + F | Return to the focused window at native size |
| Control + Option + Command + 0 | Return to actual size |
| Control + Option + Command + Z | Undo an arrangement change |
| Control + Option + Command + P | Open the command palette |

Workspace mode shows a hand in the menu bar. Within it, drag a title bar to
rearrange a window or drag its side/bottom edge to resize it. Ordinary
scrolls and rotations stay with macOS and the app;
Option-click/drag, Control-click, Shift-click, and Command-click retain their
app meanings. Set `settings.gestureActivation` to `"unmodified"` (the default) for
one-handed global workspace gestures, or `"fn"` to opt into requiring Fn
outside workspace mode. Existing custom keyboard shortcuts remain configured as
written; remove an override to adopt its new default.

On first launch, windows start in a grid. Later launches in the same login session restore the saved plane for surviving windows.
**Arrange in grid** in the menu or palette resets the arrangement; it does not
create boundaries. New windows find a nearby free position without repacking
existing windows. Movable, normal-level main windows join the workspace at their native size,
including fixed-size windows and applications with custom accessibility roles
such as Adobe Audition. Windows that belong to another window are never tiles:
dialogs and alerts, inspectors and utility panels, windows attached to a parent
window, and modal windows. Each floats above the plane and keeps its place
beside the window it belongs to, panning and zooming with it. Drag one to give
it a new place; the owner is its parent window, or else its application's
window under it. App rules (`appRules`) apply to main windows only. Elevated
system surfaces retain their separate behavior.

Native fullscreen works as it does without Tana2D: the green button, View >
Enter Full Screen, Control + Command + F, or **F11** (Fn + F11 on a laptop
keyboard; Tana2D takes the key before macOS's Show Desktop). The window goes to
its own Space and its tile leaves the plane until it returns, to the same place.
While a fullscreen application is in front, its trackpad gestures, scrolling
and clicks are its own: swipe between Spaces, pinch to zoom the page, or open
Mission Control as usual. Change the key with `"fullscreen"` in `shortcuts`.

Camera commands animate position and zoom together. Zoom preserves native
window dimensions. Control + Option + Command + M explicitly resizes the active
window to fill the screen. macOS Reduce Motion disables camera transitions.

Three-finger pan speed gets a smooth boost toward 100% zoom: 20% at native
size, 10% at 50%, and 5% at 25%, multiplied by `swipeGain`.

A three-finger pan that is still moving when the fingers lift carries on
briefly and eases to rest; a pan that stops before lifting stays exactly where
it is. At 100%, when a pan brings a window close to the center of the screen
(within 200 points of its centered view, moving toward it), the camera finishes
centering it. Small direct near-center passes also settle into place, including gentle overshoots. Ambiguous choices stay where released. Panning away from a centered window is never pulled back. Set
`"autoCenter": false` or `"panMomentum": false` to turn either off, and
`"autoCenterDistance"` (20–400 points) to change the reach. The optional
`"magneticCentering": true` setting restores a small nudge toward a nearby
window after other pans and on deliberate hover; it is off by default.

Camera transitions zoom about the one point that stays put on screen, so
zooming into a window grows it in place rather than drifting sideways. Short
hops settle faster than long trips. A command issued while the camera is
still moving (a second arrow press, or a glide interrupted by a shortcut)
keeps the part of that motion heading toward the new target, instead of
stopping and restarting.

**Show workspace** (Control + Option + Command + Return) preserves every window's world position and
uses the tight bounding rectangle of the arrangement, with a small screen margin.
**Return to window (100%)** (Control + Option + Command + 0) returns to the focused window
at **100%**.

## Separate from Tana

| Item | Tana2D |
| --- | --- |
| Application | `/Applications/Tana2D.app` |
| Executable | `build/tana2d` |
| Bundle identifier | `dev.tana2d.manager` |
| Configuration and layout | `~/Library/Application Support/Tana2D/` |
| Manager socket | `/tmp/tana2d_<user>.socket` |
| Helper socket | `/tmp/tana2d-sa_<user>.socket` |
| Privileged helper | `/Library/PrivilegedHelperTools/dev.tana2d.window-helper` |
| Scripting addition | `/Library/ScriptingAdditions/tana2d.osax` |

Tana's app, configuration, saved layouts, and helper are preserved. Tana2D does
not automatically import Tana or HorizontalWM state. The two managers share an
exclusion lock so they cannot manage windows simultaneously.

## Development

```sh
make all          # build/tana2d
make test         # geometry, runtime, configuration, setup, packaging
scripts/package.sh
open build/Tana2D.app
```

`TANA2D_SIGN_ID` selects a signing identity. Packaging remembers the selected
identity locally for subsequent builds. Release archives can be produced with
`scripts/release.sh`; they are not notarized unless explicitly configured.

Core code is in `src/`; the patched MIT-licensed yabai engine is in `vendor/yabai/`.
The internal `strip` command namespace and some source filenames are retained
for compatibility with that engine. They do not imply a bounded horizontal layout.

See [verification](docs/VERIFICATION.md) for the checks performed on this fork.

## License

MIT. Includes the MIT-licensed [yabai](https://github.com/asmvik/yabai) foundation.
The packaged app includes its third-party license notice.

### Content drags and overlap tiling

A zoomed-out body press can still click to enter a window. Once it moves five
display points, the original press is handed to the application so files, text,
and tabs retain native drag-and-drop behavior. Title bars and explicit Fn-drags
move whole windows.

During a window drag, a deliberate approach with substantial overlap offers
**Release to share screen**. Release to resize both apps into equal side-by-side
halves. At 100% the pair fills the usable screen; while zoomed out, the same
native screen-sized pair is arranged around the target. Neither app changes
size before release, and zoom stays unchanged.

Passing over a window, grazing its edge, or making a small adjustment does not
tile. Moving back away from the target withdraws the offer. Move away, press Escape, or hold
Command to decline. Fixed-size apps do not offer the split. Past resize hints cannot veto it;
the application’s actual accepted size determines whether the halves fit. If an app refuses the requested size, both
released frames are restored. Ordinary edge docking remains available as its
own gesture.

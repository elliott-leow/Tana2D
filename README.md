# Tana2D

A macOS window manager with an unbounded two-dimensional workspace. Derived from
[Tana](https://github.com/elliott-leow/Tana), developed as a separate project.

Experimental. See the [verification record](docs/VERIFICATION.md) for tested
behavior and remaining limits.

Pinch to zoom, swipe to pan. Zoom stays anchored at the pointer all the way
back to **100%** and preserves every window's size. A pinch toward 100% that
comes to rest at 90% or more finishes the zoom to exactly 100% about the same
point. There are no workspace walls.

Applications stay usable while zoomed out. From 50% up, clicks, drags,
scrolling, and typing go to the window under the pointer. Below 50%, clicking
a window focuses it and zooms in on it at 100% (the click is not passed to the
app), and dragging it moves it. Set `"zoomClickThreshold"` (0–1; default 0.5,
0 disables) to change that cutoff. At every zoom, hovering a window focuses it
and moves the focus border, just as at 100%. Zoom never remaps the pointer or
changes display configuration. Some applications track hover by polling the
cursor position themselves (Firefox, for example). Their in-app hover effects,
and menus they open at the pointer, can appear offset while zoomed out.

At 100%, hover focuses immediately without changing zoom or moving the
camera. Hover never steers the camera: while it moves, hovering does nothing,
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
| Command + Shift + Return | Reset zoom to 100% and resize the active window to fill the usable screen |
| Three-finger swipe | Browse the workspace in any direction, including diagonals |
| Pinch | Zoom out or return up to 100% |
| Control + Return / Control + Up | Zoom out to the whole workspace; press again to return to the focused window at 100% |
| Four-finger swipe down | Center the active window at 100% without resizing it |
| Four-finger swipe up | Open the same click-to-center mode |
| Command + Return | Open a new Ghostty window |
| Command + Shift + W | Open Firefox |
| Option + Command + arrow | Focus the nearest window in that direction |
| Shift + Option + Command + arrow | Move the focused window one grid step |
| Click a window below 50% zoom | Focus it and zoom in on it at 100%; dragging moves it |
| Drag a title bar, or Option-drag a window | Follow the pointer; dock beside nearby windows, with a blue bar in the gap for every docked edge |
| Hold Command while dragging | Place the window freely, without docking |
| Drag a window edge or corner | Resize in plane coordinates, preserving the opposite edge |
| Option + Command + F | Return to the focused window at native size |
| Option + Command + 0 | Return to actual size |
| Option + Command + Z | Undo an arrangement change |
| Control + Option + P | Open the command palette |

On first launch, windows start in a grid. Later launches in the same login session restore the saved plane for surviving windows.
**Arrange in grid** in the menu or palette resets the arrangement; it does not
create boundaries. New windows find a nearby free position without repacking
existing windows.

Camera commands animate position and zoom together. Zoom preserves native
window dimensions. Command + Shift + Return explicitly resizes the active
window to fill the screen. macOS Reduce Motion disables camera transitions.

A three-finger pan that is still moving when the fingers lift carries on
briefly and eases to rest; a pan that stops before lifting stays exactly where
it is. At 100%, when a pan brings a window close to the center of the screen
(within 120 points of its centered view, moving toward it), the camera finishes
centering it. Panning away from a centered window is never pulled back. Set
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

**Show workspace** (Control + Return) preserves every window's world position and
uses the tight bounding rectangle of the arrangement, with a small screen margin.
**Return to window (100%)** (Option + Command + 0) returns to the focused window
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

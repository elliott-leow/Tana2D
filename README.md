# Tana2D

A macOS window manager with an unbounded two-dimensional workspace. Derived from
[Tana](https://github.com/elliott-leow/Tana), developed as a separate project.

Experimental: scrolling and dragging are still under repair. See the
[verification record](docs/VERIFICATION.md) for current failures and tested limits.

Windows occupy positions on a plane. Move the camera horizontally or vertically
with a three-finger swipe, and pinch to zoom out or return up to 100%. **Control + Enter** or **Control + Up** zooms out so you can click a window to
center at 100%, preserving its size. Four fingers up opens the overview; four fingers
down centers the active window at 100%. There are no workspace walls.

Tana2D projects native windows through an animated WindowServer compositor backend. It is not a
set of macOS Spaces or a screenshot-only overview.

The movable camera panel has **Fit all**, **Fit window**, and a zoom percentage
button that resets the camera to **100%**.

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
| Three-finger swipe | Pan in any direction, including diagonals |
| Pinch | Zoom out or return up to 100% |
| Control + Return / Control + Up | Zoom out; click a window to center it at 100%, or drag it to move it |
| Four-finger swipe down | Center the active window at 100% without resizing it |
| Four-finger swipe up | Open the same click-to-center mode |
| Command + Return | Open a new Ghostty window |
| Command + Shift + W | Open Firefox |
| Option + Command + arrow | Focus the nearest window in that direction |
| Shift + Option + Command + arrow | Move the focused window one grid step |
| Click a window below 70% zoom | Center it at 100% without sending the click to the app; dragging only moves it |
| Drag a title bar, or Option-drag a window | Follow the pointer; preview and snap beside a nearby window on release |
| Drag a window edge or corner | Resize in plane coordinates, preserving the opposite edge |
| Option + Command + F | Fit the focused window |
| Option + Command + 0 | Return to actual size |
| Option + Command + Z | Undo an arrangement change |
| Control + Option + P | Open the command palette |

On first launch, windows start in a grid. Later launches in the same login session restore the saved plane for surviving windows.
**Arrange in grid** in the menu or palette resets the arrangement; it does not
create boundaries. New windows find a nearby free position without repacking
existing windows.

Camera commands animate position and zoom together. Command + Shift + Return also
animates the active window’s size. Escape cancels click-to-select mode; macOS
Reduce Motion disables these transitions.

After a three-finger pan toward a nearby window center, the camera nudges at most
12 screen points closer. Panning away never pulls you back. Empty canvas stays
where you leave it. Hovering does not change keyboard focus.

The camera panel is movable. **Fit all** preserves every window's world position
and uses the tight bounding rectangle of the arrangement, with a small screen
margin. **Fit window** targets the focused window. The percentage button resets
the zoom to **100%**.

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

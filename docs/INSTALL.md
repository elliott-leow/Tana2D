# Install Tana2D

Tana2D is a standalone macOS app. Its window engine and window-control helper are
included. You do not need Homebrew, Python, skhd, or an installed yabai to use it.
The engine retains its MIT-licensed yabai foundation and attribution.

## Install the app

1. Open the Tana2D disk image and drag **Tana2D.app** to **Applications** (or unzip
   the app and move it there).
2. Open **Tana2D**. Setup shows one illustrated step per screen, each with one or
   two buttons, and moves on by itself as each requirement is met: move to
   Applications, allow Accessibility, the macOS Recovery change if needed, the
   helper, then a choice of trackpad or keyboard, login startup, and a short
   interactive tour. Click **Start Tana2D** at the end.

Nothing is tiled until the checks pass. Setup resumes where it left off after
the Recovery restart: choosing **Shut Down** or **Restart** in setup registers
Tana2D to reopen at login, and the later login question keeps or removes that.
On Apple Silicon, **Turn On** adds the `-arm64e_preview_abi` boot argument with
administrator approval and preserves any existing boot arguments. The helper setup asks for administrator approval and
installs a root-owned copy with permission to run only its fixed helper-loading
command. No separate window manager or passwordless general shell is installed.

**The macOS security prerequisite is still real.** Full live off-screen placement,
window layers, and overview animations use a helper in Dock. On a stock Mac,
macOS blocks that helper: a one-time change in Recovery and a reboot are required.
The app explains this and includes an [offline setup guide](SETUP.html).
Tana2D never changes SIP or boot arguments automatically. Installing the app takes
two steps; a first-time Mac with the default security settings needs the additional
manual macOS steps. There is no reduced-feature mode hidden behind “Ready.”

Requirements: macOS 14 or later, one connected display, Accessibility permission,
“Displays have separate Spaces” enabled, and a compatible macOS window helper.
Other OS/hardware combinations need validation; a successful build alone does not
prove them supported. Locally built, ad-hoc-signed archives are not notarized public
releases. A downloaded unnotarized build may be blocked by Gatekeeper. Release
signing and notarization are supported by the packaging scripts, but require a
Developer ID and a configured notarization profile.

## Build from source

Install Xcode Command Line Tools if needed (`xcode-select --install`), then from
the downloaded repository run:

```sh
./scripts/install.sh
```

This builds, packages, installs `/Applications/Tana2D.app`, and opens setup.
`--destination "$HOME/Applications/Tana2D.app"` selects another existing parent
folder. `--no-open` installs without launching. `--no-build` reuses `build/tana2d`.
No `sudo`, package manager, or session script is needed for this step. If the
Applications folder is not writable, the script tells you to copy the built app
with Finder. Existing unrelated applications are never replaced.

For development without installing:

```sh
make all test
scripts/package.sh
open build/Tana2D.app
```

`TANA2D_SIGN_ID` selects a signing identity; the packaging script remembers it
locally. The bundle uses `dev.tana2d.manager` so Tana2D permissions can
survive updates signed with the same identity. Fresh state lives in
`~/Library/Application Support/Tana2D`. Tana and HorizontalWM settings and layouts
are never imported automatically. Tana2D requires its own Accessibility grant.

## Everyday use and accessibility

- Open **Setup & Settings** from the Tana2D menu, or open the app again. While
  Tana2D is running it shows Settings: login startup, keyboard mode, the settings
  file, and the tour.
- The menu bar is visible by default. Every command is available in the menu and
  command palette. Gestures are optional; the README lists keyboard equivalents.
- **Keyboard** in setup, or **Keyboard & screen reader mode** in Settings, turns off hover focus, reduces
  motion, disables haptics, and shows the menu bar. It keeps Spotlight and app Quit
  on their usual keys and changes the palette to **Control + Command + P**. Other
  settings, rules, and unrelated shortcuts are preserved. These preferences are
  saved in the ordinary JSON config and can be changed there.
- Custom palette rows expose labels, selection, and press actions to assistive
  technology. Camera controls use standard accessible native buttons. The UI uses native setup controls, semantic
  colors, and macOS contrast/transparency preferences. Reduce Motion is observed
  at runtime. End-to-end testing with a person using VoiceOver remains necessary.
- **Open Tana2D when I log in** uses macOS Login Items. If macOS requests approval,
  setup opens the correct settings page. Startup reloads Tana2D’s helper itself.
- **Quit Tana2D** stops managing windows and restores surviving tracked windows.
  The optional legacy migration helper below has a separate recovery journal.

Terminal and the default web browser are used unless launch commands are
customized. Set `settings.showMenuBar` to `false` to use the hidden-menu-bar
workflow. Set `settings.autofocus` to `off` to disable hover focus independently.

## Diagnose without moving windows

```sh
/Applications/Tana2D.app/Contents/MacOS/tana2d --setup-status
/Applications/Tana2D.app/Contents/MacOS/tana2d --check-backend
open -n /Applications/Tana2D.app --args --setup
open -n /Applications/Tana2D.app --args --setup-preview   # browse every screen; buttons do nothing
```

The setup page is `src/setup_ui/onboarding.html`. Opened directly in a browser it runs
on mock state: `onboarding.html?mock=fresh`, `intel`, `ready`, `settings` or `preview`.

A failed setup stays open with the next action. Another running window manager
must be quit first. Permission checks run in the launched app; calling a binary
from Terminal can inherit Terminal’s access and is not proof of the app’s grant.

Tana2D installs its own payload at `/Library/ScriptingAdditions/tana2d.osax`, uses
`/tmp/tana2d-sa_<user>.socket`, and stores the root-owned loader at
`/Library/PrivilegedHelperTools/dev.tana2d.window-helper`. The restricted sudo rule
is `/private/etc/sudoers.d/tana2d-<uid>`. These are independent of Tana’s and yabai’s files.
Dock restarts trigger a bounded automatic reconnect using Tana2D’s loader.

## Optional migration from an existing yabai session

`scripts/session.py` is retained only for existing yabai users who want a recorded
handoff and rollback. It is not part of standalone installation or startup.
After setting up Tana2D’s app permission and helper, it can snapshot the old session,
stop the recognized yabai/skhd services and Loop, and launch Tana2D:

```sh
python3 scripts/session.py start --dry-run
python3 scripts/session.py start
python3 scripts/session.py restore
```

Restoration restarts only the services it stopped and restores surviving windows
where the old manager accepts the commands. The optional script still expects the
old installation at `/opt/homebrew/bin/yabai`. Ordinary Tana2D startup never uses it.

Old development-machine launch agents are not automatically deleted. Disable an
old `dev.horizontalwm.login` launcher before enabling native Login Items to avoid
duplicate startup attempts. `scripts/login.sh` remains a compatibility wrapper
that simply opens Tana2D, without running yabai.

## Remove Tana2D

Turn off **Open Tana2D when I log in**, then quit Tana2D. If you used the optional
migration script, restore that session first. To remove the helper too, while the
app is still installed:

```sh
sudo /Applications/Tana2D.app/Contents/MacOS/tana2d --uninstall-sa
sudo rm -f /Library/PrivilegedHelperTools/dev.tana2d.window-helper "/private/etc/sudoers.d/tana2d-$(id -u)"
```

The helper is shared by Tana2D users on the Mac; remove it only when nobody else
uses Tana2D. Then move Tana2D.app to Trash. Saved settings remain in Application
Support unless you remove them yourself. Restart to unload any helper still in
Dock; the offline guide explains how to restore normal SIP settings.

## Package a release

```sh
scripts/release.sh --format dmg
```

The result is `dist/Tana2D-0.4.0.dmg`, with Tana2D.app and an Applications shortcut.
ZIP is the default format. Builds currently target the build machine’s
architecture; the embedded helper includes its own supported architectures.
For a public release use a Developer ID and a keychain notary profile:

```sh
TANA2D_SIGN_ID='Developer ID Application: …' TANA2D_NOTARIZE=1 TANA2D_NOTARY_PROFILE='…' scripts/release.sh --format dmg
```

Signing, notarization, installation on a clean Mac, real helper injection, login,
and physical gesture/VoiceOver use are distinct acceptance checks. See
[verification](VERIFICATION.md) for evidence and limitations.

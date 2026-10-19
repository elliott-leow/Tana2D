#!/bin/sh
# Build the drag-to-install disk image: the app and an Applications shortcut
# laid out over a background that says what to do.
# usage: scripts/dmg.sh APP OUTPUT.dmg
# Finder lays out the window, so this runs in a logged-in session and may ask
# once for permission to control Finder.
set -eu
[ "$#" -eq 2 ] || { printf '%s\n' 'usage: scripts/dmg.sh APP OUTPUT.dmg' >&2; exit 64; }
app=$1; output=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
[ -d "$app" ] || { printf '%s\n' "dmg.sh: missing $app" >&2; exit 1; }
volume=Tana2D
work=$(mktemp -d "${TMPDIR:-/tmp}/tana2d-dmg.XXXXXX"); device=
cleanup() { if [ -n "$device" ]; then /usr/bin/hdiutil detach "$device" -force >/dev/null 2>&1 || true; fi; rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

mkdir "$work/stage" "$work/stage/.background"
/usr/bin/ditto "$app" "$work/stage/Tana2D.app"
ln -s /Applications "$work/stage/Applications"
cp "$root_dir/assets/dmg-background.tiff" "$work/stage/.background/background.tiff"
if [ -f "$root_dir/assets/Tana2D.icns" ]; then cp "$root_dir/assets/Tana2D.icns" "$work/stage/.VolumeIcon.icns"; fi

/usr/bin/hdiutil create -volname "$volume" -srcfolder "$work/stage" -fs HFS+ -format UDRW -ov "$work/rw.dmg" >/dev/null 2>&1
# Mount under our own directory so an already-mounted "Tana2D" volume cannot be confused with this one.
mkdir "$work/mount"
device=$(/usr/bin/hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "$work/mount" 2>/dev/null | awk '/Apple_HFS/ {print $1; exit}')
[ -n "$device" ] || { printf '%s\n' 'dmg.sh: could not mount the image' >&2; exit 1; }
# A custom volume icon shows in Finder's sidebar and on the desktop.
if [ -f "$work/mount/.VolumeIcon.icns" ] && [ -x /usr/bin/SetFile ]; then /usr/bin/SetFile -a C "$work/mount"; fi

# Window content is 640x400 points; the bounds include the 28-point title bar.
/usr/bin/osascript - "$work/mount" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set theDisk to (POSIX file mountPath as alias)
        open theDisk
        set theWindow to container window of theDisk
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set pathbar visible of theWindow to false
        set sidebar width of theWindow to 0
        set bounds of theWindow to {200, 140, 840, 568}
        set viewOptions to icon view options of theWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set background picture of viewOptions to file ".background:background.tiff" of theDisk
        set position of item "Tana2D.app" of theDisk to {180, 210}
        set position of item "Applications" of theDisk to {460, 210}
        close theWindow
        open theDisk
        delay 1
        close container window of theDisk
    end tell
end run
APPLESCRIPT
sync
/usr/bin/hdiutil detach "$device" >/dev/null 2>&1; device=
mkdir -p "$(dirname -- "$output")"
/usr/bin/hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$output" >/dev/null 2>&1
printf '%s\n' "created $output"

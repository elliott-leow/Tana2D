import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "scripts" / "install.sh"
PACKAGE = ROOT / "scripts" / "package.sh"
RELEASE = ROOT / "scripts" / "release.sh"

class PackagingTests(unittest.TestCase):
    def fixture(self, directory):
        app = directory / "source app" / "Tana2D.app"; binary = app / "Contents" / "MacOS" / "tana2d"
        binary.parent.mkdir(parents=True); binary.write_text("#!/bin/sh\nexit 0\n"); binary.chmod(0o755)
        (app / "Contents" / "Info.plist").write_text('<?xml version="1.0"?><plist><dict><key>CFBundleIdentifier</key><string>dev.tana2d.manager</string></dict></plist>')
        return app
    def write_identifier(self, app, identifier):
        info = app / "Contents" / "Info.plist"; info.parent.mkdir(parents=True, exist_ok=True)
        info.write_text(f'<?xml version="1.0"?><plist><dict><key>CFBundleIdentifier</key><string>{identifier}</string></dict></plist>')
    def test_installer_replaces_existing_app_at_destination_with_spaces(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); source = self.fixture(directory); stub = directory / "package stub.sh"; args = directory / "args"
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TANA2D_TEST_ARGS"\n'); stub.chmod(0o755)
            destination = directory / "Applications Folder" / "Tana2D.app"; (destination / "old").mkdir(parents=True); self.write_identifier(destination, "dev.tana2d.manager")
            env = os.environ | {"TANA2D_APP_SOURCE": str(source), "TANA2D_PACKAGE_SCRIPT": str(stub), "TANA2D_TEST_ARGS": str(args)}
            result = subprocess.run([str(INSTALL), "--destination", str(destination), "--no-build", "--no-open"], text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr); self.assertTrue((destination / "Contents" / "MacOS" / "tana2d").is_file()); self.assertFalse((destination / "old").exists()); self.assertEqual(args.read_text().strip(), "--no-build")
    @unittest.skipUnless(Path("/usr/bin/codesign").is_file(), "macOS signing tools required")
    def test_packaged_helper_signature_survives_extraction(self):
        with tempfile.TemporaryDirectory(prefix="Tana2D package ") as raw:
            root = Path(raw)
            (root / "scripts").mkdir()
            (root / "build").mkdir()
            (root / "vendor/yabai").mkdir(parents=True)
            (root / "vendor/yabai/LICENSE.txt").write_text("Test license notice")
            script = root / "scripts/package.sh"
            shutil.copy2(PACKAGE, script)
            shutil.copyfile("/usr/bin/true", root / "build/tana2d")
            (root / "build/tana2d").chmod(0o755)
            env = os.environ | {"TANA2D_SIGN_ID": "-", "TANA2D_NOTARIZE": "0", "TANA2D_CODESIGN": "/usr/bin/codesign"}
            result = subprocess.run([str(script), "--no-build"], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            helper = root / "build/Tana2D.app/Contents/Helpers/tana2d-window-helper"
            extracted = root / "extracted helper"
            shutil.copy2(helper, extracted)
            check = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(extracted)], capture_output=True, text=True)
            self.assertEqual(check.returncode, 0, check.stderr)
            self.assertEqual(helper.read_bytes(), extracted.read_bytes())
    def test_installer_rejects_non_app_destination(self):
        result = subprocess.run([str(INSTALL), "--destination", "/tmp/Tana2D", "--no-open"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 64); self.assertIn("must end in .app", result.stderr)
    def test_installer_preserves_an_unrelated_existing_app(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); source = self.fixture(directory); stub = directory / "package.sh"; stub.write_text("#!/bin/sh\n"); stub.chmod(0o755)
            destination = directory / "Applications" / "Tana2D.app"; (destination / "keep").mkdir(parents=True); self.write_identifier(destination, "org.example.unrelated")
            env = os.environ | {"TANA2D_APP_SOURCE": str(source), "TANA2D_PACKAGE_SCRIPT": str(stub)}
            result = subprocess.run([str(INSTALL), "--destination", str(destination), "--no-open"], text=True, capture_output=True, env=env)
            self.assertNotEqual(result.returncode, 0); self.assertIn("unrelated app", result.stderr); self.assertTrue((destination / "keep").is_dir())
    def test_installer_cannot_replace_upstream_tana(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); source = self.fixture(directory)
            stub = directory / "package.sh"; stub.write_text("#!/bin/sh\n"); stub.chmod(0o755)
            destination = directory / "Applications" / "Tana2D.app"
            (destination / "keep").mkdir(parents=True)
            self.write_identifier(destination, "dev.horizontalwm.manager")
            env = os.environ | {"TANA2D_APP_SOURCE": str(source), "TANA2D_PACKAGE_SCRIPT": str(stub)}
            result = subprocess.run([str(INSTALL), "--destination", str(destination), "--no-open"], text=True, capture_output=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((destination / "keep").is_dir())
            self.assertIn("unrelated app", result.stderr)

    def test_installer_restores_previous_app_when_final_move_fails(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); source = self.fixture(directory); stub = directory / "package.sh"; stub.write_text("#!/bin/sh\n"); stub.chmod(0o755)
            destination = directory / "Applications" / "Tana2D.app"; (destination / "old").mkdir(parents=True); self.write_identifier(destination, "dev.tana2d.manager")
            tools = directory / "tools"; tools.mkdir(); fake_mv = tools / "mv"
            fake_mv.write_text('#!/bin/sh\ncase "$1" in *"/.Tana2D.install."*) [ "$2" = "$TANA2D_TEST_FAIL_DEST" ] && exit 1 ;; esac\nexec /bin/mv "$@"\n'); fake_mv.chmod(0o755)
            env = os.environ | {"TANA2D_APP_SOURCE": str(source), "TANA2D_PACKAGE_SCRIPT": str(stub), "TANA2D_TEST_FAIL_DEST": str(destination), "PATH": f"{tools}:{os.environ['PATH']}"}
            result = subprocess.run([str(INSTALL), "--destination", str(destination), "--no-open"], text=True, capture_output=True, env=env)
            self.assertNotEqual(result.returncode, 0); self.assertTrue((destination / "old").is_dir())
    def test_bundle_metadata_and_distribution_scripts_are_present(self):
        content = PACKAGE.read_text(); self.assertIn("0.6.5", content); self.assertIn("dev.tana2d.manager", content); self.assertIn("--options runtime --timestamp", content); self.assertIn("LSMinimumSystemVersion</key><string>14.0", content); self.assertIn("THIRD-PARTY-NOTICES.txt", content); self.assertIn("docs/SETUP.html", content)
        self.assertIn("--destination PATH", INSTALL.read_text()); release = RELEASE.read_text(); self.assertIn("--format zip|dmg", release); self.assertIn("TANA2D_NOTARY_PROFILE", release); self.assertIn('stapler staple "$app"', release); self.assertNotIn('stapler staple "$artifact"', release)
    def test_release_notarizes_a_temporary_zip_then_archives_stapled_app(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); source = self.fixture(directory); output = directory / "output"; tools = directory / "tools"; tools.mkdir()
            package = directory / "package.sh"; package.write_text("#!/bin/sh\n"); package.chmod(0o755)
            ditto = tools / "ditto"; ditto.write_text('#!/bin/sh\nsource=\ndestination=\nfor argument in "$@"; do source="$destination"; destination="$argument"; done\nif [ -f "$source/Contents/Resources/notarized" ]; then printf stapled > "$destination"; else printf archive > "$destination"; fi\n'); ditto.chmod(0o755)
            xcrun = tools / "xcrun"; xcrun.write_text('#!/bin/sh\nif [ "$1" = notarytool ]; then test -f "$3" && printf "%s" "$3" > "$TANA2D_TEST_SUBMISSION" || exit 1; elif [ "$1" = stapler ]; then mkdir -p "$3/Contents/Resources"; : > "$3/Contents/Resources/notarized"; fi\n'); xcrun.chmod(0o755)
            submission = directory / "submission"
            env = os.environ | {"TANA2D_APP_SOURCE": str(source), "TANA2D_PACKAGE_SCRIPT": str(package), "TANA2D_DITTO": str(ditto), "TANA2D_XCRUN": str(xcrun), "TANA2D_NOTARIZE": "1", "TANA2D_NOTARY_PROFILE": "test-profile", "TANA2D_TEST_SUBMISSION": str(submission)}
            result = subprocess.run([str(RELEASE), "--no-build", "--output", str(output)], text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr); self.assertTrue(submission.read_text().endswith(".zip")); self.assertEqual((output / "Tana2D-0.4.0.zip").read_text(), "stapled")
if __name__ == "__main__": unittest.main()

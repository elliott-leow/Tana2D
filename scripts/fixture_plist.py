"""Write metadata for the disposable live-test window fixture."""
import plistlib
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "dev.tana2d.fixture",
    "CFBundleExecutable": "Tana2DFixture",
    "CFBundleName": "Tana2DFixture",
    "CFBundleDisplayName": "Tana2DFixture",
    "CFBundlePackageType": "APPL",
}))

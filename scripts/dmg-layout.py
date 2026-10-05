"""Create the Finder layout without a loose background file in the disk image."""

from pathlib import Path
import sys
import subprocess

import dmgbuild
from ds_store import DSStore
from mac_alias import Alias

app, output = map(Path, sys.argv[1:])
mount = None


def configure_background(event):
    global mount
    if event.get("type") == "command::finished" and event.get("command") == "hdiutil::attach":
        mount = next(Path(item["mount-point"]) for item in event["output"]["system-entities"]
                     if "mount-point" in item)
    if event.get("type") == "operation::finished" and event.get("operation") == "dsstore::create":
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mount / app.name)], check=True)
        artwork = mount / app.name / "Contents/Resources/InstallerBackground.tiff"
        if not artwork.is_file():
            raise RuntimeError("Installer artwork must be bundled before signing the app.")
        with DSStore.open(str(mount / ".DS_Store"), "r+") as store:
            settings = store["."]["icvp"]
            settings["backgroundType"] = 2
            settings["backgroundImageAlias"] = Alias.for_file(str(artwork)).to_bytes()
            store["."]["icvp"] = settings


dmgbuild.build_dmg(str(output), "Meeting Notes",
                  settings_file=str(Path(__file__).with_name("dmg-settings.py")),
                  defines={"app": str(app)}, callback=configure_background)

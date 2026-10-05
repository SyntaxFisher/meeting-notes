#!/usr/bin/env python3
"""Build, sign, notarize, and publish Meeting Notes. Invoke via make."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
REPO = "SyntaxFisher/meeting-notes"
URL = f"https://github.com/{REPO}"
ACCOUNT = "com.jona.meeting-notes"
SPARKLE_VERSION = "2.10.0"
SPARKLE_SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE = BUILD / "dependencies" / f"sparkle-{SPARKLE_VERSION}"
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def run(*args, capture=False):
    args = [str(arg) for arg in args]
    print("+ " + " ".join(args), flush=True)
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def metadata():
    with (ROOT / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info["CFBundleShortVersionString"]),
            "Use a three-part release version in Info.plist.")
    require(re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]), "Use a positive integer build number.")
    require(info["CFBundleIdentifier"] == ACCOUNT, "Do not change the bundle identity.")
    return info


def dependencies():
    archive = SPARKLE.parent / f"Sparkle-{SPARKLE_VERSION}.tar.xz"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        run("curl", "--fail", "--location", "--retry", "3", "--output", temporary,
            f"https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/{archive.name}")
        require(digest(temporary) == SPARKLE_SHA256, "Sparkle checksum mismatch.")
        temporary.replace(archive)
    require(digest(archive) == SPARKLE_SHA256, "Cached Sparkle checksum mismatch.")
    # Always extract the verified distribution instead of trusting cached executables.
    if SPARKLE.exists():
        shutil.rmtree(SPARKLE)
    SPARKLE.mkdir()
    run("tar", "-xJf", archive, "-C", SPARKLE)


def sign(path, identity, release, entitlements=None):
    options = ["--options", "runtime", "--timestamp"] if release else ["--timestamp=none"]
    if entitlements:
        options += ["--entitlements", entitlements]
    run("codesign", "--force", "--sign", identity, *options, path)


def create_dmg(app, dmg):
    """Package the signed app with an explicit drag-to-Applications layout."""
    environment = BUILD / "dependencies/dmg-tools"
    python = environment / "bin/python"
    if not python.exists():
        run(sys.executable, "-m", "venv", environment)
    requirements = ROOT / "scripts/dmg-requirements.txt"
    stamp = environment / ".requirements-sha256"
    if not stamp.exists() or stamp.read_text().strip() != digest(requirements):
        run(python, "-m", "pip", "--disable-pip-version-check", "install",
            "--require-hashes", "--only-binary=:all:", "-r", requirements)
        stamp.write_text(digest(requirements) + "\n")
    run(python, ROOT / "scripts/dmg-layout.py", app, dmg)


def build(info, release=False, identity="-"):
    directory = BUILD / ("release" if release else "local")
    app = directory / "Meeting Notes.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for name in ("MacOS", "Resources", "Frameworks"):
        (contents / name).mkdir(parents=True)
    bundled_info = dict(info, MNEnableUpdater=release)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(bundled_info, stream)
    flags = shlex.split(os.environ.get("SWIFT_FLAGS", ""))
    run("xcrun", "swift", "build", "--package-path", ROOT / "NativeTranscription",
        "-c", "release", "--arch", "arm64", "--product", "MeetingTranscriber", "--force-resolved-versions")
    native = Path(run("xcrun", "swift", "build", "--package-path", ROOT / "NativeTranscription",
                      "-c", "release", "--arch", "arm64", "--show-bin-path", capture=True).strip())
    shutil.copy2(native / "MeetingTranscriber", contents / "MacOS/MeetingTranscriber")
    run("ditto", native / "FluidAudio_FluidAudio.bundle", contents / "Resources/FluidAudio_FluidAudio.bundle")
    shutil.copy2(ROOT / "NativeTranscription/.build/checkouts/FluidAudio/LICENSE", contents / "Resources/FluidAudio-LICENSE.txt")
    run("ditto", ROOT / "NativeTranscription/.build/checkouts/FluidAudio/ThirdPartyLicenses",
        contents / "Resources/ThirdPartyLicenses")
    run("xcrun", "swiftc", *flags, "-O", "-target", "arm64-apple-macos26.0",
        ROOT / "GenerateIcon.swift", "-o", directory / "GenerateIcon")
    icons = directory / "AppIcon.iconset"
    if icons.exists():
        shutil.rmtree(icons)
    run(directory / "GenerateIcon", icons)
    run("iconutil", "-c", "icns", "-o", contents / "Resources/AppIcon.icns", icons)
    shutil.copy2(SPARKLE / "LICENSE", contents / "Resources/Sparkle-LICENSE.txt")
    if release:
        artwork = BUILD / "dmg-artwork"
        run("xcrun", "swift", ROOT / "scripts/dmg-background.swift", artwork)
        run("tiffutil", "-cathidpicheck", artwork / "installer.png", artwork / "installer@2x.png",
            "-out", contents / "Resources/InstallerBackground.tiff")
    framework = contents / "Frameworks/Sparkle.framework"
    run("ditto", SPARKLE / "Sparkle.framework", framework)
    # This app is not sandboxed; Sparkle's sandbox XPC services are unnecessary.
    shutil.rmtree(framework / "Versions/B/XPCServices")
    (framework / "XPCServices").unlink()
    sources = sorted(path for path in ROOT.glob("*.swift") if path.name != "GenerateIcon.swift")
    run("xcrun", "swiftc", *flags, "-O", "-target", "arm64-apple-macos26.0",
        "-F", SPARKLE, "-framework", "Sparkle", "-Xlinker", "-rpath",
        "-Xlinker", "@executable_path/../Frameworks", *sources, "-o", contents / "MacOS/MeetingNotes")
    for component in (contents / "MacOS/MeetingTranscriber", framework / "Versions/B/Autoupdate",
                      framework / "Versions/B/Updater.app", framework):
        sign(component, identity, release)
    sign(app, identity, release, entitlements=ROOT / "Release.entitlements")
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    for name in ("MeetingNotes", "MeetingTranscriber"):
        run("lipo", contents / "MacOS" / name, "-verify_arch", "arm64")
    return app


def local_configuration():
    raw = os.environ.get("NOTARY_CONFIG")
    config_path = Path(raw).expanduser() if raw else Path.home() / ".config/meeting-notes-release/config.json"
    if not config_path.is_file():
        return {}
    require(config_path.stat().st_mode & 0o077 == 0, "Notary config must have permissions 0600.")
    return json.loads(config_path.read_text())


def notary_auth():
    profile = os.environ.get("NOTARY_PROFILE")
    if profile:
        return ["--keychain-profile", profile]
    apple = local_configuration().get("apple", {})
    require(all(apple.get(field) for field in ("key_path", "key_id", "issuer_id")),
            "Configure Apple API credentials or set NOTARY_PROFILE (see README).")
    key = Path(apple["key_path"]).expanduser()
    require(key.is_file(), "The configured Apple API private key is missing.")
    return ["--key", str(key), "--key-id", apple["key_id"], "--issuer", apple["issuer_id"]]


def notarize(path, auth, output):
    print(f"Submitting {path.name} to Apple; result will be saved to {output}", flush=True)
    process = subprocess.run(["xcrun", "notarytool", "submit", str(path), *auth,
                              "--wait", "--timeout", "20m", "--output-format", "json"],
                             cwd=ROOT, text=True, capture_output=True)
    # Preserve submission IDs/status even if waiting times out or Apple rejects the app.
    output.write_text(process.stdout)
    if process.stderr:
        output.with_suffix(".log").write_text(process.stderr)
    require(process.returncode == 0, f"Notarization did not complete; inspect {output} and its .log before retrying.")
    result = json.loads(process.stdout)
    require(result.get("status") == "Accepted", f"Notarization failed; inspect {output} and fetch the submission log.")
    print(f"Apple accepted {path.name}: {result['id']}", flush=True)


def clean_commit():
    require(not run("git", "status", "--porcelain", capture=True).strip(),
            "Commit all source changes before preparing or publishing a release.")
    return run("git", "rev-parse", "HEAD", capture=True).strip()


def verify_assets(directory, info):
    feed = directory / "appcast.xml"
    run(SPARKLE / "bin/sign_update", "--account", ACCOUNT, "--verify", feed)
    item = ET.parse(feed).find("channel/item")
    require(item is not None, "Appcast has no release.")
    require(item.findtext("sparkle:version", namespaces=NS) == info["CFBundleVersion"], "Appcast build mismatch.")
    enclosure = item.find("enclosure")
    name = f"Meeting-Notes-{info['CFBundleShortVersionString']}-macOS-arm64.dmg"
    require(enclosure.get("url") == f"{URL}/releases/download/v{info['CFBundleShortVersionString']}/{name}",
            "Appcast download URL mismatch.")
    require(int(enclosure.get("length")) == (directory / name).stat().st_size, "DMG size mismatch.")
    run(SPARKLE / "bin/sign_update", "--account", ACCOUNT, "--verify", directory / name,
        enclosure.get("{" + NS["sparkle"] + "}edSignature"))


def release(info):
    commit = clean_commit()
    auth = notary_auth()
    identity = os.environ.get("SIGN_IDENTITY") or local_configuration().get("signing", {}).get("identity")
    require(identity and identity.startswith("Developer ID Application:"), "Set SIGN_IDENTITY to your Developer ID Application certificate.")
    public_key = run(SPARKLE / "bin/generate_keys", "--account", ACCOUNT, "-p", capture=True).strip()
    require(public_key == info["SUPublicEDKey"], "Sparkle signing key does not match Info.plist.")
    version = info["CFBundleShortVersionString"]
    notes = ROOT / "releases" / f"{version}.md"
    require(notes.is_file() and notes.read_text().strip(), "Write release notes before building.")
    directory = BUILD / "releases" / version
    require(not directory.exists(), f"Release directory already exists: {directory}. Preserve completed artifacts; move aside failed builds before retrying.")
    directory.mkdir(parents=True)
    # Keep older feed entries so raising minimum macOS later does not strand users.
    releases = json.loads(run("gh", "release", "list", "--repo", REPO, "--exclude-drafts",
                             "--exclude-pre-releases", "--json", "tagName,isLatest", capture=True))
    latest = next((item for item in releases if item["isLatest"]), None)
    if latest:
        run("gh", "release", "download", latest["tagName"], "--repo", REPO,
            "--pattern", "appcast.xml", "--dir", directory)
        run(SPARKLE / "bin/sign_update", "--account", ACCOUNT, "--verify", directory / "appcast.xml")
        previous = ET.parse(directory / "appcast.xml").findall("channel/item")
        require(all(int(item.findtext("sparkle:version", namespaces=NS)) < int(info["CFBundleVersion"]) for item in previous),
                "CFBundleVersion must increase with every release.")
    app = build(info, release=True, identity=identity)
    archive = BUILD / "release/notarization.zip"
    archive.unlink(missing_ok=True)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    notarize(archive, auth, directory / "app-notarization.json")
    run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    dmg = directory / f"Meeting-Notes-{version}-macOS-arm64.dmg"
    create_dmg(app, dmg)
    sign(dmg, identity, release=True)
    notarize(dmg, auth, directory / "dmg-notarization.json")
    run("xcrun", "stapler", "staple", dmg)
    run("xcrun", "stapler", "validate", dmg)
    run("codesign", "--verify", "--strict", "--verbose=2", dmg)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg)
    shutil.copy2(notes, directory / dmg.with_suffix(".md").name)
    run(SPARKLE / "bin/generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
        "--download-url-prefix", f"{URL}/releases/download/v{version}/", "--embed-release-notes",
        "--link", URL, directory)
    verify_assets(directory, info)
    assets = [dmg, directory / "appcast.xml"]
    checksums = directory / "SHA256SUMS"
    checksums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in assets))
    assets.append(checksums)
    manifest = {"commit": commit, "version": version, "build": info["CFBundleVersion"],
                "assets": {path.name: digest(path) for path in assets}}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified release ready: {directory}\nPublish with make publish", flush=True)


def publish(info):
    commit = clean_commit()
    version = info["CFBundleShortVersionString"]
    directory = BUILD / "releases" / version
    manifest = json.loads((directory / "manifest.json").read_text())
    require(manifest["commit"] == commit and manifest["build"] == info["CFBundleVersion"],
            "Source changed since release preparation; build a new release.")
    for name, checksum in manifest["assets"].items():
        require(digest(directory / name) == checksum, f"Release asset changed: {name}")
    verify_assets(directory, info)
    remote = run("git", "ls-remote", "origin", "refs/heads/main", capture=True).split()
    require(remote and remote[0] == commit, "Push the release commit to origin/main before publishing.")
    tag = f"v{version}"
    existing = json.loads(run("gh", "release", "list", "--repo", REPO, "--limit", "100",
                             "--json", "tagName,isDraft", capture=True))
    matching = next((item for item in existing if item["tagName"] == tag), None)
    require(not matching or matching["isDraft"], "This version is already public; never replace a published release.")
    local_tag = run("git", "tag", "--list", tag, capture=True).strip()
    if local_tag:
        require(run("git", "rev-list", "-n", "1", tag, capture=True).strip() == commit, "Tag points to a different commit.")
    else:
        run("git", "tag", "-a", tag, "-m", f"Meeting Notes {version}")
    run("git", "push", "origin", f"refs/tags/{tag}")
    if not matching:
        run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--draft",
            "--title", f"Meeting Notes {version}", "--notes-file", ROOT / "releases" / f"{version}.md")
    run("gh", "release", "upload", tag, "--repo", REPO, "--clobber",
        *(directory / name for name in manifest["assets"]))
    # Verify GitHub's stored bytes while the release is still a draft.
    with tempfile.TemporaryDirectory(prefix="meeting-notes-release-") as temporary:
        run("gh", "release", "download", tag, "--repo", REPO, "--dir", temporary)
        for name, checksum in manifest["assets"].items():
            require(digest(Path(temporary) / name) == checksum, f"Remote checksum mismatch: {name}")
    run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest")
    print(f"Published {URL}/releases/tag/{tag}", flush=True)


def main():
    mode = os.environ.get("MODE", "build")
    require(mode in {"install", "build", "release", "publish", "dependencies"}, "MODE must be install, build, release, publish, or dependencies.")
    info = metadata()
    dependencies()
    if mode == "dependencies":
        return
    if mode == "release":
        release(info)
    elif mode == "publish":
        publish(info)
    else:
        app = build(info)
        if mode == "install":
            running = subprocess.run(["pgrep", "-x", "MeetingNotes"], stdout=subprocess.DEVNULL).returncode == 0
            require(not running, "Finish recording/transcription and quit Meeting Notes before installing.")
            destination = Path(os.environ.get("DEST", "/Applications")) / app.name
            if destination.exists():
                shutil.rmtree(destination)
            run("ditto", app, destination)
            run("open", destination)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        sys.exit(f"Error: {error}")

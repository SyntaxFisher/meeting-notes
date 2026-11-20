#!/usr/bin/env python3
"""Watch for new Microsoft Teams releases and check Meeting Notes against them.

Development tooling for the machine that maintains Meeting Notes; nothing here is part of the
app. Everything it keeps lives under STATE_DIR, outside the repository: archived Teams builds,
downloads and reports.

    check [--trigger]      compare the newest production Teams release with the installed one;
                           with --trigger and work pending, install the release, run the
                           regression suite and start the agent task in a new T3 thread to
                           review the results
    install [--build V]    download, verify and install the newest release, or install build V,
                           archived or downloaded, to check that Meeting Notes still works
                           with it
    verify [--scenario S]  build Meeting Notes from this checkout and record scored live
                           meetings through the local Teams test environment, one per
                           scenario (repeat --scenario; default: the regression suite, SUITE);
                           a scenario ending in "@de" is played in German Teams
    status                 print the state as JSON
    install-agent          run `check --trigger` every hour from launchd

`verify` needs the test environment of docs/development.md: Teams signed in with the test
account, a saved meeting link and the virtual audio devices. Set `localSignIdentity` in the
devenv config to a stable signing identity, so rebuilds keep the app's privacy permissions.
launchd jobs lack the Accessibility permission that driving Teams needs; set `launcher` in the
devenv config to a program that has it and runs its arguments, and install-agent starts the
check through it.

The agent task's instructions are specific to the maintainer's machine and live in TASK_FILE,
outside the repository.
"""
from __future__ import annotations

import argparse
import calendar
from contextlib import contextmanager
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
DEVENV = HERE / "devenv.py"
WORK = REPO_ROOT / "build" / "devenv"
APP = REPO_ROOT / "build" / "local" / "Meeting Notes.app"
APP_BINARY = APP / "Contents/MacOS/MeetingNotes"
TEAMS_CONTROL = WORK / "teams-control"
DEVENV_CONFIG = Path.home() / ".config" / "meeting-notes-dev" / "config.json"
APP_LOG = Path.home() / "Library/Logs/Meeting Notes/meeting-notes.log"
RECONSTRUCTION = Path.home() / "Library/Caches/com.jona.meeting-notes/reconstruction"

TEAMS = Path("/Applications/Microsoft Teams.app")
TEAMS_BUNDLE_ID = "com.microsoft.teams2"
TEAMS_SIGNER = "Developer ID Installer: Microsoft Corporation (UBF8T346G9)"
# The production ("general" ring) build that Teams clients are offered; Homebrew's livecheck
# reads the same field.
TEAMS_CONFIG_URL = ("https://config.teams.microsoft.com/config/v1/MicrosoftTeams/1.0.0.0"
                    "?environment=prod&audienceGroup=general&teamsRing=general&agent=TeamsBuilds")
# Every production build stays downloadable here, so an older build can be installed even when
# it was never archived on this machine.
TEAMS_BUILD_URL = "https://teamsinstaller.public.onecdn.static.microsoft/production-osx/{}/MicrosoftTeams.pkg"
# The Teams installer also bundles Microsoft AutoUpdate; the test machine updates Teams itself.
SKIPPED_PACKAGES = ["com.microsoft.autoupdate"]

STATE_DIR = Path.home() / "Library/Application Support/meeting-notes-dev"
STATE_FILE = STATE_DIR / "state.json"
TASK_FILE = STATE_DIR / "agent-task.md"
LOCK_FILE = STATE_DIR / "busy.lock"
BUILDS_DIR = STATE_DIR / "teams-builds"
DOWNLOADS_DIR = STATE_DIR / "downloads"
REPORTS_DIR = STATE_DIR / "reports"
LOG_DIR = Path.home() / "Library/Logs/meeting-notes-dev"
LAUNCH_AGENTS = Path.home() / "Library/LaunchAgents"
CHECK_LABEL = "dev.meeting-notes.teams-update-check"
KEEP_BUILDS = 3
RETRIGGER_AFTER_SECONDS = 12 * 3600
# The live regression suite: everything Teams has broken or could break in the app's readings.
# "@de" plays a scenario in German Teams, whose labels the app reads separately.
SUITE = [
    "standup-de-en",              # meeting window in view, multilingual, a muted aside
    "hidden-meeting",             # meeting window and compact view minimized, mute changes
    "raised-hand-lecture",        # a raised hand's frame, a covered window, Teams chat in front
    "lecture-interjections",      # short answers Teams frames late or never
    "screen-share-presentation",  # a guest presents; Teams shows her content, not her tile
    "other-desktop",              # meeting window in full screen on a desktop of its own
    "hidden-meeting@de",
    "raised-hand-lecture@de",
    "screen-share-presentation@de",
]

# A live meeting fails outright when recording does not start or stop with the call; these
# floors catch the Teams readings that degrade without failing it: participant names (named
# words and their accuracy) and mute (speech said while muted must stay out).
REQUIRED = {"namedWords": 0.5, "nameAccuracy": 0.9}
MAX_MUTED_LEAK = 0.2
# Compared with the previous Teams build's report. Word errors depend on speech recognition
# more than on Teams, so a rise only warns.
REGRESSION = {"wer": 0.05, "speakerAttribution": -0.05, "namedWords": -0.2, "nameAccuracy": -0.05}


def log(message: str) -> None:
    print(f"[teams-update] {message}", flush=True)


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    os.replace(temporary, STATE_FILE)


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def app_version(app: Path) -> str | None:
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            return plistlib.load(handle).get("CFBundleShortVersionString")
    except (OSError, plistlib.InvalidFileException):
        return None


def devenv_config() -> dict:
    try:
        return json.loads(DEVENV_CONFIG.read_text())
    except (OSError, ValueError):
        return {}


def latest_release() -> dict:
    request = urllib.request.Request(TEAMS_CONFIG_URL, headers={"User-Agent": "teams-update-check"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return parse_release(json.load(response))


def parse_release(config: dict) -> dict:
    build = (config.get("BuildSettings") or {}).get("WebView2Canary", {}).get("macOS") or {}
    if not build.get("latestVersion") or not build.get("buildLink"):
        raise RuntimeError("the Teams configuration names no macOS build")
    return {"version": build["latestVersion"], "url": build["buildLink"]}


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO_ROOT), *args], capture_output=True,
                          text=True).stdout.strip()


# MARK: check


def pending_work(state: dict, latest: dict | None, installed: str | None) -> dict | None:
    if latest is not None and installed is not None \
            and version_key(latest["version"]) > version_key(installed):
        return {"action": "install", "version": latest["version"], "installed": installed}
    if installed is not None and state.get("verified", {}).get("version") != installed:
        return {"action": "verify", "version": installed, "installed": installed}
    return None


@contextmanager
def exclusive():
    """Keeps installs and suite runs from overlapping, e.g. the hourly check and an agent."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_FILE.open("w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another teams_update.py install or verify is running") from None
        yield


def prepare(work: dict) -> str:
    """Installs and verifies the pending build; returns what was done, for the agent."""
    lines = []
    if work["action"] == "install":
        try:
            install_latest()
            subprocess.run(["/usr/bin/open", "-g", str(TEAMS)], check=True)
            lines.append(f"- Installed Teams {work['version']} (was {work['installed']}).")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            lines.append(f"- Installing Teams {work['version']} failed: {error}")
            return "\n".join(lines)
    try:
        result = run_suite(SUITE)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        lines.append(f"- The regression suite could not run: {error}")
        return "\n".join(lines)
    lines.append(f"- Ran the regression suite on Teams {app_version(TEAMS)}: verdict "
                 f"{result['verdict']}; report in {result['report']} (summary.md, report.json "
                 "and one log per scenario).")
    lines += [f"  - {reason}" for reason in result["reasons"]]
    return "\n".join(lines)


def start_agent_task(work: dict, prepared: str) -> bool:
    try:
        task = TASK_FILE.read_text()
    except OSError:
        log(f"no agent task at {TASK_FILE}")
        return False
    task += ("\n## Already done by the update check\n\n"
             f"Pending was: {work['action']} Teams {work['version']}.\n{prepared}\n")
    t3 = shutil.which("t3") or str(Path.home() / ".local/bin/t3")
    result = subprocess.run(
        [t3, "thread", "start", "--title", f"Teams {work['version']}: compatibility check",
         str(REPO_ROOT), "-"],
        input=task, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        log(f"t3 thread start failed: {(result.stderr or result.stdout).strip()[-400:]}")
    return result.returncode == 0


def command_check(trigger: bool) -> int:
    state = load_state()
    archive_installed_build()
    try:
        latest = latest_release()
    except (OSError, ValueError, RuntimeError) as error:
        log(f"Teams configuration unreachable: {error}")
        latest = None
    installed = app_version(TEAMS)
    work = pending_work(state, latest, installed)
    state["last_check"] = {"at": time.time(), "latest": latest and latest["version"],
                           "installed": installed}
    triggered = state.get("triggered", {})
    if trigger and work is not None:
        recent = (triggered.get("version") == work["version"]
                  and time.time() - triggered.get("at", 0) < RETRIGGER_AFTER_SECONDS)
        if recent:
            log(f"agent already started for {work['version']}")
        else:
            save_state(state)
            log(f"preparing {work['action']} {work['version']} for the agent")
            try:
                with exclusive():
                    prepared = prepare(work)
            except RuntimeError as error:
                log(f"not now: {error}")
                return 0
            state = load_state()
            if start_agent_task(work, prepared):
                state["triggered"] = {"version": work["version"], "action": work["action"],
                                      "at": time.time()}
                log(f"started the agent task: {work['action']} {work['version']}")
    save_state(state)
    print(json.dumps({"pending": work, "latest": latest and latest["version"],
                      "installed": installed}))
    return 0


# MARK: install


def archived_builds() -> list[tuple[str, Path]]:
    builds = [(path.name, path / TEAMS.name) for path in BUILDS_DIR.glob("*")
              if (path / TEAMS.name / "Contents/Info.plist").is_file()]
    return sorted(builds, key=lambda item: version_key(item[0]))


def archive_installed_build() -> None:
    """Keeps a copy of the installed Teams so a later run can reinstall it.

    The copy is an APFS clone, so it costs no space until the original changes.
    """
    version = app_version(TEAMS)
    if version is None:
        return
    target = BUILDS_DIR / version / TEAMS.name
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-cR", str(TEAMS), str(target)], check=True)
    log(f"archived Teams {version}")
    for old_version, path in archived_builds()[:-KEEP_BUILDS]:
        shutil.rmtree(path.parent, ignore_errors=True)
        log(f"removed archived Teams {old_version}")


def teams_running() -> bool:
    return subprocess.run(["/usr/bin/pgrep", "-x", "MSTeams"], capture_output=True).returncode == 0


def quit_teams() -> None:
    if not teams_running():
        return
    subprocess.run(["/usr/bin/osascript", "-e", f'tell application id "{TEAMS_BUNDLE_ID}" to quit'],
                   capture_output=True)
    deadline = time.monotonic() + 30
    while teams_running() and time.monotonic() < deadline:
        time.sleep(0.5)
    if teams_running():
        subprocess.run(["/usr/bin/pkill", "-x", "MSTeams"])
        time.sleep(5)
    if teams_running():
        raise RuntimeError("Teams did not quit")


def sudo(*args: str) -> None:
    result = subprocess.run(["/usr/bin/sudo", "-n", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"sudo {args[0]} failed: {(result.stderr or result.stdout).strip()}")


def download(url: str, target: Path) -> None:
    if target.is_file():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(".part")
    log(f"downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "teams-update-check"})
    with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as handle:
        shutil.copyfileobj(response, handle, length=1 << 20)
    os.replace(partial, target)


def check_package_signature(package: Path) -> None:
    result = subprocess.run(["/usr/sbin/pkgutil", "--check-signature", str(package)],
                            capture_output=True, text=True)
    if result.returncode != 0 or TEAMS_SIGNER not in result.stdout \
            or "Notarization: trusted" not in result.stdout:
        package.unlink(missing_ok=True)
        raise RuntimeError("the download is not a notarized installer signed by Microsoft")


def choice_changes() -> Path:
    changes = [{"choiceIdentifier": package, "choiceAttribute": "selected", "attributeSetting": 0}
               for package in SKIPPED_PACKAGES]
    handle = tempfile.NamedTemporaryFile(suffix=".plist", delete=False)
    with handle:
        plistlib.dump(changes, handle)
    return Path(handle.name)


def install_latest() -> int:
    latest = latest_release()
    installed = app_version(TEAMS)
    if installed is not None and version_key(latest["version"]) <= version_key(installed):
        log(f"Teams {installed} is the newest release")
        return 0
    archive_installed_build()
    package = DOWNLOADS_DIR / f"MicrosoftTeams-{latest['version']}.pkg"
    download(latest["url"], package)
    check_package_signature(package)
    quit_teams()
    changes = choice_changes()
    try:
        sudo("/usr/sbin/installer", "-pkg", str(package), "-target", "/",
             "-applyChoiceChangesXML", str(changes))
    finally:
        changes.unlink(missing_ok=True)
    if app_version(TEAMS) != latest["version"]:
        raise RuntimeError(f"installed Teams is {app_version(TEAMS)}, not {latest['version']}")
    package.unlink(missing_ok=True)
    archive_installed_build()
    log(f"installed Teams {latest['version']} (was {installed})")
    return 0


def archive_download(version: str) -> Path:
    """Downloads build `version` and archives the app it installs.

    The installer refuses to replace a newer Teams, so the app comes out of the package instead.
    """
    package = DOWNLOADS_DIR / f"MicrosoftTeams-{version}.pkg"
    try:
        download(TEAMS_BUILD_URL.format(version), package)
    except OSError as error:
        raise RuntimeError(f"Teams {version} could not be downloaded: {error}") from error
    check_package_signature(package)
    expanded = Path(tempfile.mkdtemp(prefix="teams-pkg-", dir=DOWNLOADS_DIR))
    try:
        subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded / "pkg")],
                       check=True, capture_output=True)
        apps = [path for path in (expanded / "pkg").glob(f"*/Payload/{TEAMS.name}")
                if app_version(path) == version]
        if not apps:
            raise RuntimeError(f"the Teams {version} package holds no {TEAMS.name} {version}")
        target = BUILDS_DIR / version / TEAMS.name
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["/usr/bin/ditto", str(apps[0]), str(target)], check=True)
    finally:
        shutil.rmtree(expanded, ignore_errors=True)
    package.unlink(missing_ok=True)
    log(f"archived downloaded Teams {version}")
    return target


def install_archived(version: str) -> int:
    if app_version(TEAMS) == version:
        log(f"Teams {version} is already installed")
        return 0
    # Archiving first keeps its cleanup from removing the build about to be installed.
    archive_installed_build()
    source = dict(archived_builds()).get(version) or archive_download(version)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
    quit_teams()
    staged = TEAMS.with_name(f".{TEAMS.name}.staged")
    retired = TEAMS.with_name(f".{TEAMS.name}.retired")
    sudo("/bin/rm", "-rf", str(staged), str(retired))
    sudo("/usr/bin/ditto", str(source), str(staged))
    sudo("/usr/sbin/chown", "-R", "root:wheel", str(staged))
    sudo("/bin/mv", str(TEAMS), str(retired))
    try:
        sudo("/bin/mv", str(staged), str(TEAMS))
    except RuntimeError:
        sudo("/bin/mv", str(retired), str(TEAMS))
        raise
    sudo("/bin/rm", "-rf", str(retired))
    log(f"reinstalled archived Teams {version}")
    return 0


def command_install(build: str | None) -> int:
    result = install_archived(build) if build else install_latest()
    subprocess.run(["/usr/bin/open", "-g", str(TEAMS)], check=True)
    return result


# MARK: verify


def teams_control(*args: str) -> subprocess.CompletedProcess[str]:
    if not TEAMS_CONTROL.exists():
        WORK.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-O", "-o", str(TEAMS_CONTROL),
                        str(HERE / "TeamsControl.swift")], check=True)
    return subprocess.run([str(TEAMS_CONTROL), *args], capture_output=True, text=True)


def ensure_teams_signed_in() -> None:
    if not teams_running():
        subprocess.run(["/usr/bin/open", str(TEAMS)], check=True)
    # Teams' sign-in and main views load only while it is the active app.
    subprocess.run(["/usr/bin/osascript", "-e", f'tell application id "{TEAMS_BUNDLE_ID}" to activate'],
                   capture_output=True)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if teams_control("find", r"^(Activity|Aktivität|Leave|Verlassen)$").returncode == 0:
            return
        if teams_control("find", r"^(Sign in|Anmelden)$").returncode == 0:
            raise RuntimeError("Teams is signed out; sign in the test account again")
        time.sleep(3)
    raise RuntimeError("Teams did not finish loading")


def run_logged(command: list[str], output: Path, environment: dict | None = None,
               timeout: float = 1800) -> int:
    with output.open("w") as handle:
        try:
            return subprocess.run(command, cwd=REPO_ROOT, stdout=handle, stderr=subprocess.STDOUT,
                                  env=environment, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            handle.write(f"\ntimed out after {timeout:.0f} s\n")
            return 124


def build_app(out: Path) -> None:
    environment = dict(os.environ)
    identity = devenv_config().get("localSignIdentity")
    if identity:
        environment["LOCAL_SIGN_IDENTITY"] = identity
    else:
        log("no localSignIdentity in the devenv config; the ad-hoc build may lose permissions")
    if run_logged(["make", "build"], out / "build.log", environment) != 0:
        raise RuntimeError(f"make build failed; see {out / 'build.log'}")


def app_status() -> str:
    result = subprocess.run([str(APP_BINARY), "status"], capture_output=True, text=True)
    return " ".join(result.stdout.split())


def running_app_paths() -> list[str]:
    output = subprocess.run(["/bin/ps", "-axo", "args="], capture_output=True, text=True).stdout
    return [line.split("/Contents/MacOS/MeetingNotes")[0] for line in output.splitlines()
            if "/Contents/MacOS/MeetingNotes" in line and "MeetingTranscriber" not in line]


def restart_app() -> None:
    """Runs the freshly built app, once whatever copy is running is idle."""
    if running_app_paths():
        deadline = time.monotonic() + 1800
        while not app_status().startswith("Ready") and time.monotonic() < deadline:
            time.sleep(10)
        subprocess.run(["/usr/bin/pkill", "-x", "MeetingNotes"])
        for _ in range(30):
            if not running_app_paths():
                break
            time.sleep(1)
    subprocess.run(["/usr/bin/open", str(APP)], check=True)
    for _ in range(30):
        time.sleep(2)
        status = app_status()
        if status.startswith("Ready"):
            return
    raise RuntimeError(f"Meeting Notes is not ready to record: {status}")


def split_run(run: str) -> tuple[str, str]:
    """A suite entry's scenario and Teams language: "hidden-meeting@de" is German Teams."""
    scenario, _, language = run.partition("@")
    return scenario, language or "en"


def set_teams_language(language: str, output: Path) -> None:
    with output.open("a") as handle:
        result = subprocess.run([sys.executable, str(DEVENV), "teams-language", language],
                                cwd=REPO_ROOT, stdout=handle, stderr=subprocess.STDOUT,
                                timeout=300)
    if result.returncode != 0:
        raise RuntimeError(f"Teams did not switch to language {language}; see {output}")


def newest_report(scenario: str, since: float) -> dict | None:
    reports = [path for path in (WORK / "scenarios" / scenario).glob("live-*.report.json")
               if path.stat().st_mtime >= since]
    if not reports:
        return None
    return json.loads(max(reports, key=lambda path: path.stat().st_mtime).read_text())


# Events the app logs when Teams reads or capture go wrong without failing the meeting.
TROUBLE_EVENTS = {"error", "teams.slowRead", "teams.refreshFailed", "capture.failed"}
# Teams answers slowly for some seconds while it lays out a window again: entering and leaving
# full screen in other-desktop alone stalls about 20 reads by around a second. Slow reads only
# warn when one takes this long or they come this often during the run.
SLOW_READ_SECONDS = 2.0
SLOW_READS_PER_MINUTE = 2.0


def app_log_since(since: float) -> dict:
    """Trouble the app logged during the run, with the slowest Teams read and the run's length."""
    counts: dict[str, int] = {}
    errors = []
    slowest = 0.0
    minutes = round((time.time() - since) / 60, 1)
    try:
        lines = APP_LOG.read_text(errors="replace").splitlines()
    except OSError:
        return {"counts": counts, "errors": errors, "slowestRead": slowest, "minutes": minutes}
    for line in lines:
        try:
            entry = json.loads(line)
            stamp = calendar.timegm(time.strptime(entry["time"], "%Y-%m-%dT%H:%M:%SZ"))
        except (ValueError, KeyError, TypeError):
            continue
        if stamp < since:
            continue
        event = entry.get("event", "")
        if event in TROUBLE_EVENTS:
            counts[event] = counts.get(event, 0) + 1
        if event == "error":
            errors.append(entry.get("detail"))
        if event == "teams.slowRead":
            seconds = re.search(r"=([0-9.]+)s", entry.get("detail", ""))
            slowest = max(slowest, float(seconds[1]) if seconds else SLOW_READ_SECONDS)
    return {"counts": counts, "errors": errors[-10:], "slowestRead": slowest, "minutes": minutes}


def app_log_reasons(app_log: dict) -> list[str]:
    """Yellow reasons from the app log: every trouble event, except slow Teams reads that stay
    short and rare."""
    reasons = []
    for event, count in app_log.get("counts", {}).items():
        if event == "teams.slowRead":
            slowest = app_log.get("slowestRead", SLOW_READ_SECONDS)
            minutes = app_log.get("minutes", 0)
            if slowest < SLOW_READ_SECONDS and count <= SLOW_READS_PER_MINUTE * minutes:
                continue
            reasons.append(f"the app logged {count} x {event} in {minutes} min, "
                           f"the slowest {slowest} s")
        else:
            reasons.append(f"the app logged {count} x {event}")
    return reasons


def previous_report(version: str) -> dict | None:
    candidates = sorted(
        (path for path in REPORTS_DIR.glob("*/report.json")
         if version_key(path.parent.name) < version_key(version)),
        key=lambda path: version_key(path.parent.name))
    for path in reversed(candidates):
        report = json.loads(path.read_text())
        if any(run.get("score") for run in report.get("runs", [])):
            return report
    return None


def verdict_for(report: dict) -> tuple[str, list[str]]:
    reasons = []
    level = "green"
    order = ["green", "yellow", "red"]

    def raise_to(new: str, reason: str) -> None:
        nonlocal level
        if order.index(new) > order.index(level):
            level = new
        reasons.append(f"{new}: {reason}")

    if report.get("error"):
        raise_to("red", report["error"])
    previous = report.get("previous") or {}
    earlier = {run["scenario"]: run.get("score") or {} for run in previous.get("runs", [])}
    for run in report["runs"]:
        name, score = run["scenario"], run.get("score")
        if run["meeting_exit"] not in (None, 0):
            raise_to("red", f"{name}: the live meeting failed (exit {run['meeting_exit']}); "
                            f"see {name}.log")
        if run["meeting_exit"] == 0 and not score:
            raise_to("red", f"{name}: the live meeting produced no scored transcript")
        if not score:
            continue
        for key, floor in REQUIRED.items():
            if (score.get(key) or 0) < floor:
                raise_to("red", f"{name}: {key} is {score.get(key)}, below {floor}")
        if (score.get("mutedSpeechLeaked") or 0) > MAX_MUTED_LEAK:
            raise_to("red", f"{name}: speech said while muted leaked ({score['mutedSpeechLeaked']})")
        if score.get("speakersDetected") != score.get("speakersExpected"):
            raise_to("yellow", f"{name}: {score.get('speakersDetected')} speakers detected, "
                               f"{score.get('speakersExpected')} expected")
        before = earlier.get(name, {})
        for key, limit in REGRESSION.items():
            if score.get(key) is None or before.get(key) is None:
                continue
            change = score[key] - before[key]
            if (limit > 0 and change > limit) or (limit < 0 and change < limit):
                raise_to("yellow", f"{name}: {key} changed from {before[key]} to {score[key]} "
                                   f"since Teams {previous['teams']}")
    for reason in app_log_reasons(report.get("app_log", {})):
        raise_to("yellow", reason)
    return level, reasons


def summary_markdown(report: dict) -> str:
    previous = report.get("previous") or {}
    earlier = {run["scenario"]: run.get("score") or {} for run in previous.get("runs", [])}
    lines = [
        f"# Teams {report['teams']}: {report['verdict'].upper()}",
        "",
        f"- Meeting Notes: {report['meeting_notes']}",
        f"- Scenarios: {', '.join(run['scenario'] for run in report['runs'])}",
        f"- Compared with: Teams {previous.get('teams')} ({previous.get('meeting_notes')})"
        if previous else "- Compared with: nothing (first run)",
        "",
        "## Reasons" if report["reasons"] else "## Reasons\n\nNone; every check passed.",
    ]
    lines += [f"- {reason}" for reason in report["reasons"]]
    app_log = report.get("app_log", {})
    if app_log.get("counts"):
        lines += ["", "## App log", ""]
        lines += [f"- {count} x {event}" for event, count in app_log["counts"].items()]
        if app_log.get("slowestRead"):
            lines.append(f"- slowest Teams read: {app_log['slowestRead']} s "
                         f"in {app_log.get('minutes')} min")
    for run in report["runs"]:
        if not run.get("score"):
            continue
        before = earlier.get(run["scenario"], {})
        lines += ["", f"## {run['scenario']}", "", f"- Meeting: {run['score'].get('meeting')}"]
        if run.get("reconstruction"):
            lines.append(f"- Teams trace and capture: {run['reconstruction']}")
        lines += ["", "| | now | before |", "|---|---|---|"]
        for key, value in run["score"].items():
            if key not in ("transcript", "meeting", "werByLanguage"):
                lines.append(f"| {key} | {value} | {before.get(key, '')} |")
    lines += ["", "## Files", "",
              "- build.log, " + ", ".join(f"{run['scenario']}.log" for run in report["runs"])
              + ", report.json"]
    return "\n".join(lines) + "\n"


def run_suite(runs: list[str]) -> dict:
    version = app_version(TEAMS)
    if version is None:
        raise RuntimeError(f"{TEAMS} is not installed")
    if not devenv_config().get("meetingUrl"):
        raise RuntimeError("no meeting link; save one with `devenv.py config --url`")
    archive_installed_build()
    out = REPORTS_DIR / version
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    report = {"teams": version, "runs": [],
              "meeting_notes": git("describe", "--tags", "--always", "--dirty") or None,
              "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    started = time.time()
    try:
        log("building Meeting Notes")
        build_app(out)
        log("starting Meeting Notes and Teams")
        restart_app()
        for name in runs:
            scenario, language = split_run(name)
            ensure_teams_signed_in()
            set_teams_language(language, out / "teams-language.log")
            log(f"live meeting: {name}")
            run_started = time.time()
            run = {"scenario": name, "meeting_exit": None, "score": None}
            report["runs"].append(run)
            run["meeting_exit"] = run_logged(
                [sys.executable, str(DEVENV), "meeting", scenario, "--leave", "--score"],
                out / f"{name}.log")
            run["score"] = newest_report(scenario, run_started)
            meeting = (run["score"] or {}).get("meeting")
            if meeting and (RECONSTRUCTION / meeting).is_dir():
                run["reconstruction"] = str(RECONSTRUCTION / meeting)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    finally:
        subprocess.run([sys.executable, str(DEVENV), "audio", "off"], cwd=REPO_ROOT,
                       capture_output=True)
        if any(split_run(name)[1] != "en" for name in runs):
            try:
                set_teams_language("en", out / "teams-language.log")
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                report.setdefault("error", str(error))
    report["app_log"] = app_log_since(started)
    previous = previous_report(version)
    if previous:
        report["previous"] = {key: previous.get(key) for key in ("teams", "meeting_notes", "runs")}
    report["verdict"], report["reasons"] = verdict_for(report)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "summary.md").write_text(summary_markdown(report))
    state = load_state()
    state["verified"] = {"version": version, "verdict": report["verdict"], "at": time.time(),
                         "meeting_notes": report["meeting_notes"], "report": str(out)}
    save_state(state)
    return {"verdict": report["verdict"], "reasons": report["reasons"], "report": str(out)}


# MARK: launchd


def launchctl(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True)


def command_install_agent() -> None:
    launcher = devenv_config().get("launcher")
    configuration = {
        "Label": CHECK_LABEL,
        "ProgramArguments": ([launcher] if launcher else [])
        + [sys.executable, str(Path(__file__).resolve()), "check", "--trigger"],
        # The suite builds the app and plays audio with tools from the installing shell's PATH.
        "EnvironmentVariables": {"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        "StartInterval": 3600,
        "RunAtLoad": True,
        "WorkingDirectory": str(REPO_ROOT),
        "StandardOutPath": str(LOG_DIR / "teams-update-check.log"),
        "StandardErrorPath": str(LOG_DIR / "teams-update-check.log"),
    }
    plist = LAUNCH_AGENTS / f"{CHECK_LABEL}.plist"
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=plist.parent, delete=False) as handle:
        plistlib.dump(configuration, handle, sort_keys=False)
    os.replace(handle.name, plist)
    plist.chmod(0o644)
    domain = f"gui/{os.getuid()}"
    launchctl("bootout", f"{domain}/{CHECK_LABEL}")
    result = launchctl("bootstrap", domain, str(plist))
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    log(f"installed {plist}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="compare the newest Teams release with the installed one")
    check.add_argument("--trigger", action="store_true",
                       help="start the agent task in a new T3 thread when work is pending")
    install = sub.add_parser("install", help="install the newest Teams release")
    install.add_argument("--build", metavar="VERSION",
                         help="reinstall this archived Teams build instead")
    verify = sub.add_parser("verify", help="record and score live meetings with this checkout")
    verify.add_argument("--scenario", action="append", dest="scenarios",
                        help="devenv scenario to play, with @de for German Teams; repeat for "
                             f"several (default {', '.join(SUITE)})")
    sub.add_parser("status", help="print the state as JSON")
    sub.add_parser("install-agent", help="run `check --trigger` every hour from launchd")
    args = parser.parse_args()
    try:
        if args.command == "check":
            return command_check(args.trigger)
        if args.command == "install":
            with exclusive():
                return command_install(args.build)
        if args.command == "verify":
            with exclusive():
                result = run_suite(args.scenarios or SUITE)
            print(json.dumps(result, indent=2))
            return 0
        if args.command == "status":
            state = load_state()
            state["archived"] = [version for version, _ in archived_builds()]
            print(json.dumps(state, indent=2))
        elif args.command == "install-agent":
            command_install_agent()
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        log(f"failed: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

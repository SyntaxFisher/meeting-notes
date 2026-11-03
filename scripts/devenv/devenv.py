#!/usr/bin/env python3
"""Local Teams test environment for Meeting Notes.

Simulates a realistic meeting on this Mac: the Teams desktop app hosts a real meeting,
remote participants are anonymous browser guests whose microphones play synthetic speech, and
the local participant speaks through a virtual microphone. Scenarios are scripted, so every
transcript can be scored against a known reference. See docs/development.md.
"""

import argparse
import base64
import calendar
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import wave

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORK = ROOT / "build" / "devenv"
VENV = WORK / "venv"
SCENARIOS = HERE / "scenarios"
CONFIG = Path.home() / ".config" / "meeting-notes-dev" / "config.json"
TRANSCRIPTS = Path.home() / "Documents" / "meeting-notes" / "transcripts"
APP = ROOT / "build" / "local" / "Meeting Notes.app"
TEAMS = "Microsoft Teams"
# The local speaker plays into this device; it becomes the default input for Teams and the app.
MIC_DEVICE = "BlackHole 2ch"
# Teams playback goes to this unmonitored device. The app's process tap still captures it.
SINK_DEVICE = "BlackHole 16ch"
RATE = 48_000
BREW = ["ffmpeg", "switchaudio-osx"]
CASKS = ["microsoft-teams", "blackhole-2ch", "blackhole-16ch"]


def run(*args, capture=False, check=True, quiet=False):
    args = [str(arg) for arg in args]
    if not quiet:
        print("+ " + " ".join(args), flush=True)
    result = subprocess.run(args, check=check, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout if capture else result.returncode


def fail(message):
    sys.exit(f"devenv: {message}")


def config():
    return json.loads(CONFIG.read_text()) if CONFIG.exists() else {}


def save_config(values):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps({**config(), **values}, indent=2) + "\n")
    CONFIG.chmod(0o600)


# MARK: setup and audio routing

def devices(kind="all"):
    return run("SwitchAudioSource", "-a", "-t", kind, capture=True, quiet=True).splitlines()


def setup(_):
    installed = set(run("brew", "list", "--formula", "-1", capture=True, quiet=True).split())
    missing = [name for name in BREW if name not in installed]
    if missing:
        run("brew", "install", *missing)
    casks = set(run("brew", "list", "--cask", "-1", capture=True, quiet=True).split())
    missing = [name for name in CASKS if name not in casks]
    if missing:
        run("brew", "install", "--cask", *missing)
    if not {MIC_DEVICE, SINK_DEVICE} <= set(devices()):
        # Loads the BlackHole HAL plug-ins without a reboot.
        run("sudo", "killall", "coreaudiod")
        for _ in range(20):
            time.sleep(1)
            if {MIC_DEVICE, SINK_DEVICE} <= set(devices()):
                break
        else:
            fail("BlackHole devices did not appear; reboot and run setup again.")
    if not (VENV / "bin" / "playwright").exists():
        run(sys.executable, "-m", "venv", VENV)
        run(VENV / "bin" / "pip", "install", "--quiet", "playwright")
    run(VENV / "bin" / "playwright", "install", "chromium")
    print("Setup complete. Next: sign in to Teams, then `devenv.py meeting --url <link>`.")


def audio(args):
    state = WORK / "audio-defaults.json"
    current = {kind: run("SwitchAudioSource", "-c", "-t", kind, capture=True, quiet=True).strip()
               for kind in ("input", "output", "system")}
    if args.mode == "status":
        print(json.dumps({"current": current, "saved": json.loads(state.read_text())
                          if state.exists() else None}, indent=2))
        return
    if args.mode == "on":
        if not state.exists():
            WORK.mkdir(parents=True, exist_ok=True)
            state.write_text(json.dumps(current))
        targets = {"input": MIC_DEVICE, "output": SINK_DEVICE, "system": SINK_DEVICE}
    else:
        if not state.exists():
            print("Audio routing is not managed by devenv.")
            return
        targets = json.loads(state.read_text())
    for kind, name in targets.items():
        run("SwitchAudioSource", "-t", kind, "-s", name, quiet=True, capture=True)
    if args.mode == "off":
        state.unlink()
    print(f"Audio routing {args.mode}: " + ", ".join(f"{k}={v}" for k, v in targets.items()))


def ensure_audio_routing():
    if run("SwitchAudioSource", "-c", "-t", "input", capture=True, quiet=True).strip() != MIC_DEVICE:
        audio(argparse.Namespace(mode="on"))


# MARK: scenarios

def load_scenario(name):
    path = Path(name)
    if not path.exists():
        path = SCENARIOS / f"{name}.json"
    if not path.exists():
        fail(f"Unknown scenario {name}. Available: " +
             ", ".join(sorted(p.stem for p in SCENARIOS.glob("*.json"))))
    scenario = json.loads(path.read_text())
    scenario.setdefault("name", path.stem)
    scenario["path"] = str(path)
    return scenario


def wav_duration(path):
    with wave.open(str(path)) as audio_file:
        return audio_file.getnframes() / audio_file.getframerate()


def render(scenario):
    """Synthesizes every turn and writes a timeline, reference transcript, and mixed recording."""
    directory = WORK / "scenarios" / scenario["name"]
    clips = directory / "clips"
    clips.mkdir(parents=True, exist_ok=True)
    speakers = scenario["speakers"]
    # `gap` is the pause before a step; a negative gap makes a turn overlap the previous one.
    events, clock, muted = [], float(scenario.get("leadIn", 1.0)), False
    default_gap = float(scenario.get("gap", 0.7))
    for index, step in enumerate(scenario["steps"]):
        if "pause" in step:
            clock += float(step["pause"])
            continue
        if step.get("action") in ("mute", "unmute"):
            muted = step["action"] == "mute"
            at = clock + float(step.get("gap", 0.5))
            events.append({"at": round(at, 3), "action": step["action"]})
            # Leave time for Teams and the app's mute mirroring to observe the change.
            clock = at + 1.0
            continue
        speaker = speakers[step["speaker"]]
        voice = step.get("voice", speaker.get("voice"))
        clip = clips / f"{index:03d}.wav"
        key = json.dumps([voice, step.get("rate", speaker.get("rate")), step["text"],
                          step.get("audio")])
        stamp = clip.with_suffix(".key")
        if not clip.exists() or not stamp.exists() or stamp.read_text() != key:
            synthesize(step, voice, step.get("rate", speaker.get("rate")), clip, Path(scenario["path"]))
            stamp.write_text(key)
        first = not any("clip" in event for event in events)
        start = max(0.0, clock + (0.0 if first else float(step.get("gap", default_gap))))
        duration = wav_duration(clip)
        local = speaker.get("via") == "mic"
        events.append({
            "at": round(start, 3), "end": round(start + duration, 3), "speaker": step["speaker"],
            "via": "mic" if local else "guest", "lang": step.get("lang", speaker.get("lang")),
            "text": step["text"], "clip": str(clip), "muted": local and muted})
        clock = max(clock, start + duration)
    truth = {"name": scenario["name"], "speakers": speakers, "events": events,
             "duration": round(clock + 1.0, 3)}
    (directory / "truth.json").write_text(json.dumps(truth, indent=2, ensure_ascii=False) + "\n")
    mix(truth, directory / "mix.wav")
    return directory, truth


def synthesize(step, voice, rate, output, scenario_path):
    if step.get("audio"):
        source = (scenario_path.parent / step["audio"]).resolve()
    else:
        handle, temporary = tempfile.mkstemp(suffix=".aiff")
        os.close(handle)
        source = Path(temporary)
        command = ["say", "-v", voice, "-o", str(source)]
        if rate:
            command += ["-r", str(rate)]
        subprocess.run(command + ["--", step["text"]], check=True)
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", source, "-af",
        "loudnorm=I=-23:TP=-2", "-ar", RATE, "-ac", "1", "-sample_fmt", "s16", output, quiet=True)
    if not step.get("audio"):
        source.unlink()


def mix(truth, output):
    """The recording the app should produce: every turn except microphone speech while muted."""
    audible = [event for event in truth["events"] if "clip" in event and not event["muted"]]
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    filters = []
    for index, event in enumerate(audible):
        command += ["-i", event["clip"]]
        delay = int(event["at"] * 1000)
        filters.append(f"[{index}]adelay={delay}|{delay}[a{index}]")
    labels = "".join(f"[a{index}]" for index in range(len(audible)))
    filters.append(f"{labels}amix=inputs={len(audible)}:normalize=0,"
                   f"apad=whole_dur={truth['duration']}[out]")
    command += ["-filter_complex", ";".join(filters), "-map", "[out]", "-ar", str(RATE),
                "-ac", "1", str(output)]
    subprocess.run(command, check=True)


def render_command(args):
    directory, truth = render(load_scenario(args.scenario))
    clips = [event for event in truth["events"] if "clip" in event]
    print(f"Rendered {len(clips)} turns ({truth['duration']:.0f} s) to {directory}")


# MARK: scoring

TRANSCRIPT_LINE = re.compile(r"^\[(\d+):(\d+):(\d+)\] Speaker (\d+): (.*)$")


def words(text):
    text = unicodedata.normalize("NFKC", text).lower().replace("’", "'")
    return re.findall(r"[\w']+", text)


def align(reference, hypothesis):
    """Word-level Levenshtein alignment returning (reference index | None, hypothesis index | None)."""
    rows, columns = len(reference) + 1, len(hypothesis) + 1
    cost = [[0] * columns for _ in range(rows)]
    for i in range(rows):
        cost[i][0] = i
    for j in range(columns):
        cost[0][j] = j
    for i in range(1, rows):
        for j in range(1, columns):
            same = reference[i - 1] == hypothesis[j - 1]
            cost[i][j] = min(cost[i - 1][j - 1] + (0 if same else 1),
                             cost[i - 1][j] + 1, cost[i][j - 1] + 1)
    pairs, i, j = [], rows - 1, columns - 1
    while i or j:
        if i and j and cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i and cost[i][j] == cost[i - 1][j] + 1:
            pairs.append((i - 1, None))
            i -= 1
        else:
            pairs.append((None, j - 1))
            j -= 1
    return pairs[::-1]


def score(transcript_path, truth):
    lines = [TRANSCRIPT_LINE.match(line.strip())
             for line in Path(transcript_path).read_text().splitlines() if line.strip()]
    segments = [(int(m[4]), m[5]) for m in lines if m]
    expected = [event for event in truth["events"] if "clip" in event and not event["muted"]]
    reference = [(word, event["lang"], event["speaker"])
                 for event in expected for word in words(event["text"])]
    hypothesis = [(word, label) for label, text in segments for word in words(text)]
    pairs = align([word for word, _, _ in reference], [word for word, _ in hypothesis])
    languages, errors = {}, {}
    for word, lang, _ in reference:
        languages[lang] = languages.get(lang, 0) + 1
    confusion, last_lang = {}, reference[0][1] if reference else "?"
    for ref, hyp in pairs:
        lang = reference[ref][1] if ref is not None else last_lang
        last_lang = lang
        if ref is None or hyp is None or reference[ref][0] != hypothesis[hyp][0]:
            errors[lang] = errors.get(lang, 0) + 1
        if ref is not None and hyp is not None:
            key = (hypothesis[hyp][1], reference[ref][2])
            confusion[key] = confusion.get(key, 0) + 1
    # Each detected label maps to the scripted speaker it most often transcribes.
    labels = {label for label, _ in segments}
    attributed = sum(max((n for (label, _), n in confusion.items() if label == hyp_label),
                         default=0) for hyp_label in labels)
    matched = sum(confusion.values())
    other_words = {word for word, _, _ in reference}
    leaks = []
    for event in truth["events"]:
        if event.get("muted"):
            distinctive = {w for w in words(event["text"]) if len(w) > 3} - other_words
            heard = distinctive & {word for word, _ in hypothesis}
            if distinctive:
                leaks.append(len(heard) / len(distinctive))
    report = {
        "transcript": str(transcript_path),
        "wer": round(sum(errors.values()) / max(1, len(reference)), 3),
        "werByLanguage": {lang: round(errors.get(lang, 0) / count, 3)
                          for lang, count in sorted(languages.items())},
        "speakersExpected": len({event["speaker"] for event in expected}),
        "speakersDetected": len(labels),
        "speakerAttribution": round(attributed / max(1, matched), 3),
        "mutedSpeechLeaked": round(max(leaks), 3) if leaks else None,
    }
    return report


def print_report(report):
    print(f"Transcript:            {report['transcript']}")
    print(f"Word error rate:       {report['wer']:.1%}")
    for lang, value in report["werByLanguage"].items():
        print(f"  {lang:<20} {value:.1%}")
    print(f"Speakers:              {report['speakersDetected']} detected, "
          f"{report['speakersExpected']} expected")
    print(f"Speaker attribution:   {report['speakerAttribution']:.1%} of aligned words")
    if report["mutedSpeechLeaked"] is not None:
        print(f"Muted speech leaked:   {report['mutedSpeechLeaked']:.0%} of distinctive words")


def score_command(args):
    scenario = load_scenario(args.scenario)
    truth_path = WORK / "scenarios" / scenario["name"] / "truth.json"
    truth = json.loads(truth_path.read_text()) if truth_path.exists() else render(scenario)[1]
    report = score(args.transcript, truth)
    print_report(report)
    if args.json:
        print(json.dumps(report, indent=2))


def transcriber():
    for candidate in (APP / "Contents/MacOS/MeetingTranscriber",
                      ROOT / "NativeTranscription/.build/arm64-apple-macosx/release/MeetingTranscriber"):
        if candidate.exists():
            return candidate
    fail("MeetingTranscriber not found; run `make build` first.")


def offline(args):
    """Transcribes the scenario's ideal mix directly, without Teams or live capture."""
    scenario = load_scenario(args.scenario)
    directory, truth = render(scenario)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    output = directory / f"offline-{stamp}.txt"
    progress = directory / f"offline-{stamp}.progress.json"
    started = time.monotonic()
    result = subprocess.run([str(transcriber()), str(directory / "mix.wav"), str(output),
                             str(progress)])
    if result.returncode != 0:
        fail(f"Transcription failed: {progress.read_text() if progress.exists() else result}")
    print(f"Transcribed {truth['duration']:.0f} s of audio in {time.monotonic() - started:.0f} s")
    report = score(output, truth)
    (directory / f"offline-{stamp}.report.json").write_text(json.dumps(report, indent=2) + "\n")
    print_report(report)


# MARK: Teams desktop

CONTROL = WORK / "teams-control"


def teams_control(*args, check=False):
    """Presses Teams buttons through Accessibility (Teams' web UI is invisible to plain AX)."""
    source = HERE / "TeamsControl.swift"
    if not CONTROL.exists() or CONTROL.stat().st_mtime < source.stat().st_mtime:
        WORK.mkdir(parents=True, exist_ok=True)
        run("xcrun", "swiftc", "-O", "-o", CONTROL, source, quiet=True)
    result = subprocess.run([str(CONTROL), *args], text=True, capture_output=True)
    if check and result.returncode != 0:
        fail(result.stderr.strip() or f"teams-control {' '.join(args)} failed")
    return result


def teams_running():
    return subprocess.run(["pgrep", "-x", "MSTeams"], capture_output=True).returncode == 0


def desktop_join(url):
    """Opens the meeting in Teams desktop and presses Join now on its pre-join screen."""
    if not teams_running():
        run("open", "-a", TEAMS)
        time.sleep(10)
    if teams_control("find", r"^(Leave|Verlassen)$").returncode == 0:
        print("Teams desktop is already in a meeting.")
        return
    run("open", "-a", TEAMS, re.sub(r"^https://", "msteams://", url))
    for _ in range(30):
        time.sleep(2)
        if teams_control("find", r"^(Join now|Jetzt teilnehmen)$").returncode:
            continue
        # Teams remembers its own speaker choice; anything but the sink plays the meeting aloud.
        if teams_control("find", rf"^Selected speaker: {SINK_DEVICE}\b").returncode:
            print(f"Warning: Teams is not using {SINK_DEVICE} as its speaker; pick it on the "
                  "pre-join screen to keep meetings silent.")
        if teams_control("press", r"^(Join now|Jetzt teilnehmen)$").returncode == 0:
            print("Teams desktop joined the meeting.")
            time.sleep(4)
            return
    fail("Teams desktop did not show Join now; check the Teams window.")


def desktop_set_muted(muted):
    """Clicks the Teams microphone button unless it already shows the wanted state."""
    target = r"^(Mute mic|Mikrofon stummschalten)" if muted else \
        r"^(Unmute mic|Mikrofon wieder aktivieren)"
    if teams_control("press", target, "--meeting").returncode != 0:
        print(f"  (Teams mic already {'muted' if muted else 'unmuted'} or button not found)")


ADMIT = r"^(Admit all|Admit participant in lobby|Admit$|Alle zulassen|Zulassen)"


def desktop_admit():
    """Admits lobby guests from the People pane; Teams free has no lobby-bypass option."""
    if teams_control("press", ADMIT, "--meeting").returncode == 0:
        return True
    if teams_control("find", r"^(Close participants pane|Teilnehmerbereich schließen)",
                     "--meeting").returncode:
        teams_control("press", r"^(People|Personen)$", "--meeting")
        time.sleep(1.5)
    return teams_control("press", ADMIT, "--meeting").returncode == 0


def desktop_leave():
    teams_control("press", r"^(Leave|Verlassen)$", "--meeting")


# MARK: browser guests

GUEST_ARGS = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
              "--autoplay-policy=no-user-gesture-required"]


def guest_frames(page):
    frames = []
    for frame in page.frames:
        try:
            if frame.evaluate("() => !!(window.__meetingNotesGuest && __meetingNotesGuest.captured)"):
                frames.append(frame)
        except Exception:
            pass
    return frames


def web_join_url(url):
    """The Teams light-meetings page that anonymous browser guests end up on.

    Opening the meeting link itself goes through a launcher and an SSO check that never finishes
    for anonymous headless guests, so build the final URL directly from the code and passcode.
    """
    import urllib.parse
    parsed = urllib.parse.urlparse(url)
    code = parsed.path.rstrip("/").rsplit("/", 1)[-1]
    passcode = urllib.parse.parse_qs(parsed.query).get("p", [""])[0]
    coords = base64.b64encode(json.dumps(
        {"meetingUrl": url, "meetingCode": code, "passcode": passcode},
        separators=(",", ":")).encode()).decode()
    query = urllib.parse.urlencode({
        "p": passcode, "anon": "true", "launchType": "web", "agent": "web",
        "lightExperience": "true", "coords": coords})
    return f"https://teams.live.com/light-meetings/launch?{query}"


def start_guest(page, url, name):
    """Fills in the anonymous pre-join screen and presses Join now."""
    page.goto(web_join_url(url), wait_until="domcontentloaded", timeout=60000)
    field = page.locator('[data-tid="prejoin-display-name-input"]')
    field.wait_for(timeout=60000)
    field.fill(name)
    camera = page.locator('[data-tid="toggle-video"]')
    if camera.count() and camera.is_checked():
        camera.click()
    page.get_by_role("button", name=re.compile(r"^(Join now|Jetzt teilnehmen)", re.I)).click()


def guest_in_call(page):
    return page.get_by_role("button", name=re.compile(r"^(Leave|Verlassen)")).count() > 0


def wait_for_guests(pages, admit, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        waiting = [name for name, page in pages.items() if not guest_in_call(page)]
        if not waiting:
            return
        if admit:
            desktop_admit()
        time.sleep(2)
    for name, page in pages.items():
        if not guest_in_call(page):
            page.screenshot(path=str(WORK / f"guest-{name}.png"))
    fail(f"Guests not admitted: {', '.join(waiting)}; screenshots are in {WORK}.")


def meeting(args):
    url = args.url or config().get("meetingUrl")
    if not url:
        fail("Pass --url with a Teams meeting link or save one with `devenv.py config --url`.")
    scenario = load_scenario(args.scenario)
    directory, truth = render(scenario)
    ensure_audio_routing()
    if not args.no_desktop:
        desktop_join(url)
    guests = {key: value for key, value in truth["speakers"].items() if value.get("via") != "mic"}
    sys.path.insert(0, str(next((VENV / "lib").glob("python*/site-packages"))))
    from playwright.sync_api import sync_playwright
    ffmpeg_index = audiotoolbox_index(MIC_DEVICE)
    started = time.time()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=not args.headed, channel="chromium", args=GUEST_ARGS)
        pages = {}
        for key, speaker in guests.items():
            context = browser.new_context(
                permissions=["microphone", "camera"], viewport={"width": 1280, "height": 800})
            context.add_init_script(path=str(HERE / "guest-audio.js"))
            page = context.new_page()
            print(f"Joining guest {speaker.get('display', key)}…", flush=True)
            start_guest(page, url, speaker.get("display", key))
            pages[key] = page
        wait_for_guests(pages, admit=not args.no_desktop)
        frames = {}
        for key, page in pages.items():
            frames[key] = guest_frames(page) or [page.main_frame]
        for event in truth["events"]:
            if event.get("via") == "guest":
                data = base64.b64encode(Path(event["clip"]).read_bytes()).decode()
                for frame in frames[event["speaker"]]:
                    frame.evaluate("([id, data]) => __meetingNotesGuest.load(id, data)",
                                   [event["clip"], data])
        print(f"Everyone joined. Playing {scenario['name']} ({truth['duration']:.0f} s)…",
              flush=True)
        time.sleep(float(args.settle))
        origin = time.monotonic()
        players = []
        for event in truth["events"]:
            delay = origin + event["at"] - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            label = event.get("action") or f"{event['speaker']}: {event['text'][:60]}"
            print(f"  [{event['at']:6.1f}s] {label}", flush=True)
            if event.get("action"):
                desktop_set_muted(event["action"] == "mute")
            elif event["via"] == "mic":
                players.append(subprocess.Popen(
                    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-i", event["clip"],
                     "-f", "audiotoolbox", "-audio_device_index", str(ffmpeg_index), "-"]))
            else:
                for frame in frames[event["speaker"]]:
                    frame.evaluate("(id) => __meetingNotesGuest.play(id)", event["clip"])
        remaining = origin + truth["duration"] - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        for player in players:
            player.wait()
        if args.leave and not args.no_desktop:
            desktop_leave()
        browser.close()
    print("Scenario finished.")
    if args.score:
        wait_and_score(started, truth, directory, float(args.score_timeout))


def audiotoolbox_index(name):
    output = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "lavfi", "-i", "anullsrc", "-t", "0.01", "-f",
         "audiotoolbox", "-list_devices", "true", "-"], capture_output=True, text=True).stderr
    for line in output.splitlines():
        match = re.search(r"\[(\d+)\]\s+(.+?), ", line)
        if match and match[2].strip() == name:
            return int(match[1])
    fail(f"Audio device {name} not found.")


def wait_and_score(started, truth, directory, timeout):
    print("Waiting for Meeting Notes to write the transcript…", flush=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        fresh = [path for path in TRANSCRIPTS.glob("*.txt") if path.stat().st_mtime > started]
        if fresh:
            transcript = max(fresh, key=lambda path: path.stat().st_mtime)
            time.sleep(1)
            report = score(transcript, truth)
            stamp = time.strftime("%Y%m%d-%H%M%S")
            (directory / f"live-{stamp}.report.json").write_text(json.dumps(report, indent=2) + "\n")
            print_report(report)
            return
        time.sleep(3)
    fail(app_error_since(started) or
         "No new transcript appeared. Is Auto-Record on, or did you start recording manually?")


def app_error_since(started):
    """The last error Meeting Notes logged after `started`, if any."""
    log = Path.home() / "Library/Logs/Meeting Notes/meeting-notes.log"
    if not log.exists():
        return None
    error = None
    for line in log.read_text(errors="replace").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        stamp = calendar.timegm(time.strptime(entry.get("time", ""), "%Y-%m-%dT%H:%M:%SZ"))
        if stamp >= started and entry.get("event") == "error":
            error = entry.get("detail")
    return f"Meeting Notes reported an error: {error}" if error else None


def config_command(args):
    if args.url:
        save_config({"meetingUrl": args.url})
    print(json.dumps(config(), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup", help="install tools, virtual audio devices and Playwright")
    command = commands.add_parser("audio", help="route default audio through virtual devices")
    command.add_argument("mode", choices=["on", "off", "status"])
    command = commands.add_parser("render", help="synthesize a scenario's audio and reference")
    command.add_argument("scenario")
    command = commands.add_parser("offline", help="transcribe a scenario mix without Teams")
    command.add_argument("scenario")
    command = commands.add_parser("score", help="score a transcript against a scenario")
    command.add_argument("scenario")
    command.add_argument("transcript")
    command.add_argument("--json", action="store_true")
    command = commands.add_parser("meeting", help="play a scenario in a live Teams meeting")
    command.add_argument("scenario")
    command.add_argument("--url", help="Teams meeting link (defaults to the saved one)")
    command.add_argument("--headed", action="store_true", help="show the guest browser")
    command.add_argument("--no-desktop", action="store_true",
                         help="do not join with Teams desktop (already in the meeting)")
    command.add_argument("--leave", action="store_true", help="leave in Teams desktop at the end")
    command.add_argument("--score", action="store_true", help="wait for the transcript and score it")
    command.add_argument("--score-timeout", default=600)
    command.add_argument("--settle", default=4, help="seconds to wait after everyone joined")
    command = commands.add_parser("config", help="show or save local settings")
    command.add_argument("--url", help="default Teams meeting link")
    args = parser.parse_args()
    handlers = {"setup": setup, "audio": audio, "render": render_command, "offline": offline,
                "score": score_command, "meeting": meeting, "config": config_command}
    handlers[args.command](args)


if __name__ == "__main__":
    main()

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
from contextlib import contextmanager
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
PLAYBACK_PREROLL = 5
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


def mix(truth, output, include=lambda event: True, codec=(), *, include_muted=False):
    """The recording the app should produce: every turn except microphone speech while muted.
    `include` selects the turns, for example one side of the call."""
    audible = [event for event in truth["events"]
               if "clip" in event and (include_muted or not event["muted"]) and include(event)]
    if not audible:
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
            "-i", f"anullsrc=r={RATE}:cl=mono", "-t", str(truth["duration"]),
            *codec, output, quiet=True)
        return
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-filter_complex_threads", "2"]
    filters = []
    for index, event in enumerate(audible):
        command += ["-threads", "1", "-i", event["clip"]]
        delay = int(event["at"] * 1000)
        filters.append(f"[{index}]adelay={delay}|{delay}[a{index}]")
    labels = "".join(f"[a{index}]" for index in range(len(audible)))
    filters.append(f"{labels}amix=inputs={len(audible)}:normalize=0,"
                   f"apad=whole_dur={truth['duration']}[out]")
    command += ["-filter_complex", ";".join(filters), "-map", "[out]", "-ar", str(RATE),
                "-ac", "1", "-threads", "2", *codec, str(output)]
    subprocess.run(command, check=True)


def synthetic_capture(scenario, truth, directory):
    """A capture folder as the app writes it during a Teams call: the local speaker's unmuted
    turns in the microphone track and the guests in the Teams track, both starting together."""
    capture = directory / "capture"
    capture.mkdir(exist_ok=True)
    local = {key for key, speaker in scenario["speakers"].items() if speaker.get("via") == "mic"}
    adts = ("-c:a", "aac", "-b:a", "96k", "-f", "adts")
    mix(truth, capture / "microphone.aac", lambda event: event["speaker"] in local, adts)
    mix(truth, capture / "system.aac", lambda event: event["speaker"] not in local, adts)
    (capture / "capture.json").write_text(json.dumps({"microphoneStart": 0, "systemStart": 0, "systemAudio": "teams"}))
    return capture


def render_command(args):
    directory, truth = render(load_scenario(args.scenario))
    clips = [event for event in truth["events"] if "clip" in event]
    print(f"Rendered {len(clips)} turns ({truth['duration']:.0f} s) to {directory}")


# MARK: scoring

# Header lines never start with a timestamp; labels are "Speaker N" or a name.
TRANSCRIPT_LINE = re.compile(r"^\[(\d+):(\d+):(\d+)\] ([^:]+?): (.*)$")


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


def claimed_identities(transcript_path, truth):
    """Maps transcript labels that claim an identity to the scripted speaker they name.

    The local label comes from the meeting record (`is_local_user`); other labels count
    as names when they equal a guest's display name. "Speaker N" labels claim nothing.
    """
    claims = {}
    path = Path(transcript_path)
    sidecar = path.with_suffix(".json")
    local = next((key for key, speaker in truth["speakers"].items()
                  if speaker.get("via") == "mic"), None)
    if sidecar.exists():
        for speaker in json.loads(sidecar.read_text()).get("speakers", []):
            if (speaker.get("is_local_user") or speaker.get("identity") == "local-user") and local:
                claims[speaker["label"]] = local
    for key, speaker in truth["speakers"].items():
        if speaker.get("display"):
            claims.setdefault(speaker["display"], key)
    return claims


def best_assignment(confusion, labels, speakers):
    """Words attributed under the best one-to-one mapping of labels to scripted speakers."""
    import itertools
    labels, speakers = sorted(labels), sorted(speakers)
    if len(labels) > 7 or len(speakers) > 7:
        used, total = set(), 0
        for (label, speaker), count in sorted(confusion.items(), key=lambda item: -item[1]):
            if label not in used and speaker not in used:
                used |= {label, speaker}
                total += count
        return total
    best = 0
    slots = speakers + [None] * max(0, len(labels) - len(speakers))
    for permutation in itertools.permutations(slots, len(labels)):
        best = max(best, sum(confusion.get((label, speaker), 0)
                             for label, speaker in zip(labels, permutation) if speaker))
    return best


def score(transcript_path, truth):
    lines = [TRANSCRIPT_LINE.match(line.strip())
             for line in Path(transcript_path).read_text().splitlines() if line.strip()]
    segments = [(m[4], m[5]) for m in lines if m]
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
    claims = claimed_identities(transcript_path, truth)
    named = sum(n for (label, _), n in confusion.items() if label in claims)
    named_right = sum(n for (label, speaker), n in confusion.items()
                      if claims.get(label) == speaker)
    one_to_one = best_assignment(confusion, labels, {event["speaker"] for event in expected})
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
        "speakerAttributionOneToOne": round(one_to_one / max(1, matched), 3),
        "namedWords": round(named / max(1, matched), 3),
        "nameAccuracy": round(named_right / named, 3) if named else None,
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
    print(f"  one label per person {report['speakerAttributionOneToOne']:.1%}")
    named = report["namedWords"]
    accuracy = report["nameAccuracy"]
    print(f"Named words:           {named:.1%}" +
          (f", {accuracy:.1%} with the right name" if accuracy is not None else ""))
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


def app_binary():
    binary = APP / "Contents/MacOS/MeetingNotes"
    if not binary.exists():
        fail(f"{binary} not found; run `make build` first.")
    return binary


def offline(args):
    """Transcribes the scenario's ideal mix like the app, without Teams or live capture."""
    scenario = load_scenario(args.scenario)
    directory, truth = render(scenario)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    output = directory / f"offline-{stamp}{'-tracks' if args.tracks else ''}.txt"
    command = [str(app_binary()), "transcribe", str(directory / "mix.wav"), str(output)]
    if args.tracks:
        command += ["--capture", str(synthetic_capture(scenario, truth, directory))]
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"Transcription failed: {result.stderr.strip() or result.stdout.strip()}")
    if args.tracks:
        audible = [event for event in truth["events"] if "clip" in event and not event["muted"]]
        if audible and all(event["via"] == "mic" for event in audible):
            record = json.loads(output.with_suffix(".json").read_text())
            if (record["transcription"]["mode"] != "separate-tracks"
                    or not record["speakers"]
                    or any(not speaker["is_local_user"] or speaker["source"] != "microphone"
                           for speaker in record["speakers"])):
                fail("Solo call lost its microphone speaker identity")
    print(f"Transcribed {truth['duration']:.0f} s of audio in {time.monotonic() - started:.0f} s")
    report = score(output, truth)
    (directory / f"offline-{stamp}.report.json").write_text(json.dumps(report, indent=2) + "\n")
    print_report(report)


def shift_filter(seconds):
    """An ffmpeg filter that moves a track later (positive) or earlier (negative) in time."""
    if seconds >= 0:
        delay = int(round(seconds * 1000))
        return f"adelay={delay}|{delay}"
    return f"atrim=start={-seconds:.4f},asetpts=PTS-STARTPTS"


def replay(args):
    """Transcribes an archived live capture with the tracks mixed (as before) and separately.

    Live captures are archived when the app's `captureArchiveDirectory` default is set. With
    `--echo`, a delayed, filtered copy of the Teams track is added to the microphone track, which
    simulates a call without headphones; `--echo-room` makes that copy sound like laptop speakers.
    """
    scenario = load_scenario(args.scenario)
    truth_path = WORK / "scenarios" / scenario["name"] / "truth.json"
    truth = json.loads(truth_path.read_text()) if truth_path.exists() else render(scenario)[1]
    capture = Path(args.capture).expanduser()
    manifest = json.loads((capture / "capture.json").read_text())
    if manifest.get("systemStart") is None or manifest.get("microphoneStart") is None:
        fail("The capture needs both a microphone and a Teams track.")
    suffix = f"-echo{args.echo:g}{'-room' if args.echo_room else ''}" if args.echo else ""
    directory = WORK / "replays" / f"{scenario['name']}{suffix}-{time.strftime('%Y%m%d-%H%M%S')}"
    tracks = directory / "capture"
    tracks.mkdir(parents=True)
    for name in ("capture.json", "system.aac", "participants.json", "speaking.json"):
        if (capture / name).exists():
            shutil.copy2(capture / name, tracks / name)
    ffmpeg = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    microphone, system = capture / "microphone.aac", capture / "system.aac"
    if args.echo:
        lag = manifest["systemStart"] - manifest["microphoneStart"] + args.echo_delay
        path = (
            # Laptop speakers into the built-in microphone: reflections, a saturating speaker
            # and a level that drifts as people move, unlike a clean linear copy.
            "highpass=f=300,lowpass=f=6000,aecho=0.8:0.6:23|41|67|113:0.5|0.4|0.3|0.2,"
            f"asoftclip=type=tanh:threshold=0.5,volume='{args.echo}*(1+0.5*sin(2*PI*t/5.3))'"
            ":eval=frame" if args.echo_room else f"lowpass=f=3800,highpass=f=150,volume={args.echo}")
        run(*ffmpeg, "-i", microphone, "-i", system, "-filter_complex",
            f"[1]{shift_filter(lag)},{path}[echo];"
            "[0][echo]amix=inputs=2:normalize=0:duration=first[out]",
            "-map", "[out]", "-ar", RATE, "-ac", "1", "-c:a", "aac", "-b:a", "96k", "-f", "adts",
            tracks / "microphone.aac", quiet=True)
    else:
        shutil.copy2(microphone, tracks / "microphone.aac")
    origin = min(manifest["systemStart"], manifest["microphoneStart"])
    mix_path = directory / f"{capture.name}.wav"
    run(*ffmpeg, "-i", tracks / "microphone.aac", "-i", tracks / "system.aac", "-filter_complex",
        f"[0]{shift_filter(manifest['microphoneStart'] - origin)}[m];"
        f"[1]{shift_filter(manifest['systemStart'] - origin)}[s];"
        "[m][s]amix=inputs=2:normalize=0:duration=longest[out]",
        "-map", "[out]", "-ar", RATE, "-ac", "1", mix_path, quiet=True)
    binary = app_binary()
    reports = {}
    for mode in args.modes.split(","):
        output = directory / f"{mode}.txt"
        command = [binary, "transcribe", mix_path, output, "--name", args.name]
        if mode == "separate":
            command += ["--capture", tracks]
        started = time.monotonic()
        run(*command, quiet=True)
        print(f"{mode}: transcribed in {time.monotonic() - started:.0f} s")
        reports[mode] = score(output, truth)
        (directory / f"{mode}.report.json").write_text(json.dumps(reports[mode], indent=2) + "\n")
    print_comparison(reports)
    print(f"Results: {directory}")


def print_comparison(reports):
    rows = [("WER", "wer", "{:.1%}"), ("Speakers detected", "speakersDetected", "{}"),
            ("Speakers expected", "speakersExpected", "{}"),
            ("Attribution", "speakerAttribution", "{:.1%}"),
            ("Attribution, one label per person", "speakerAttributionOneToOne", "{:.1%}"),
            ("Named words", "namedWords", "{:.1%}"), ("Name accuracy", "nameAccuracy", "{:.1%}"),
            ("Muted speech leaked", "mutedSpeechLeaked", "{:.0%}")]
    modes = list(reports)
    print(f"{'':36}" + "".join(f"{mode:>12}" for mode in modes))
    for title, key, form in rows:
        values = [reports[mode].get(key) for mode in modes]
        print(f"{title:36}" + "".join(
            f"{form.format(value) if value is not None else '-':>12}" for value in values))


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
            # Teams can join muted (for example after a large meeting); scenarios start unmuted.
            desktop_set_muted(False)
            return
    fail("Teams desktop did not show Join now; check the Teams window.")


def desktop_set_muted(muted):
    """Clicks the Teams microphone button unless it already shows the wanted state."""
    target = r"^(Mute mic|Mikrofon stummschalten)" if muted else \
        r"^(Unmute mic|Mikrofon wieder aktivieren)"
    expected = r"^(Unmute mic|Mikrofon wieder aktivieren)" if muted else \
        r"^(Mute mic|Mikrofon stummschalten)"
    if teams_control("press", target, "--meeting").returncode != 0:
        if teams_control("find", expected, "--meeting").returncode == 0:
            return
        fail(f"Cannot set Teams mic to {'muted' if muted else 'unmuted'}.")
    for _ in range(10):
        if teams_control("find", expected, "--meeting").returncode == 0:
            return
        time.sleep(0.2)
    fail("Teams microphone button did not confirm the requested state.")


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


@contextmanager
def guest_browser(playwright, args):
    browser = playwright.chromium.launch(
        headless=not args.headed, channel="chromium",
        args=GUEST_ARGS + ["--num-raster-threads=1", "--disable-background-media-suspend"])
    try:
        yield browser
    finally:
        try:
            for context in browser.contexts:
                for page in context.pages:
                    try:
                        leave = page.get_by_role("button", name=re.compile(r"^(Leave|Verlassen)"))
                        if leave.count():
                            leave.first.click(timeout=3000)
                    except Exception:
                        pass
        finally:
            try:
                browser.close()
            finally:
                if args.leave and not args.no_desktop:
                    if teams_control("find", r"^(Leave|Verlassen)$", "--meeting").returncode == 0:
                        desktop_leave()


@contextmanager
def microphone_playback(clip, device_index, progress):
    player = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "1", "-re",
         "-readrate_initial_burst", "0",
         "-i", str(clip), "-threads", "2", "-stats_period", "0.1",
         "-progress", str(progress), "-f", "audiotoolbox", "-audio_device_index",
         str(device_index), "-"])
    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if player.poll() is not None:
                fail("Microphone playback exited before its audio clock started.")
            if progress.exists():
                positions = re.findall(r"^out_time_us=(\d+)$", progress.read_text(), re.M)
                if positions:
                    # Playback has five seconds of silence before the scenario timeline.
                    origin = time.monotonic() + PLAYBACK_PREROLL - int(positions[-1]) / 1_000_000
                    yield player, origin
                    return
            time.sleep(0.02)
        fail("Microphone playback did not start within 15 seconds.")
    finally:
        if player.poll() is None:
            player.terminate()
            try:
                player.wait(timeout=5)
            except subprocess.TimeoutExpired:
                player.kill()
                player.wait()


def meeting(args):
    url = args.url or config().get("meetingUrl")
    if not url:
        fail("Pass --url with a Teams meeting link or save one with `devenv.py config --url`.")
    scenario = load_scenario(args.scenario)
    directory, truth = render(scenario)
    microphone = directory / "microphone-playback.wav"
    playback = {**truth, "duration": truth["duration"] + PLAYBACK_PREROLL,
                "events": [{**event, "at": event["at"] + PLAYBACK_PREROLL}
                           for event in truth["events"]]}
    mix(playback, microphone, lambda event: event["via"] == "mic", include_muted=True)
    ensure_audio_routing()
    # Auto-record starts when the desktop joins, long before every guest is admitted.
    joined = time.time() - (30 if args.no_desktop else 5)
    if not args.no_desktop:
        desktop_join(url)
    guests = {key: value for key, value in truth["speakers"].items() if value.get("via") != "mic"}
    sys.path.insert(0, str(next((VENV / "lib").glob("python*/site-packages"))))
    from playwright.sync_api import sync_playwright
    ffmpeg_index = audiotoolbox_index(MIC_DEVICE)
    rounds = max(1, int(args.repeat))
    if rounds > 1 and (not args.leave or args.no_desktop):
        fail("--repeat needs --leave and the Teams desktop, which leaves and rejoins.")
    with sync_playwright() as playwright, guest_browser(playwright, args) as browser:
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
        starts = []
        for round_index in range(rounds):
            if round_index:
                # Back to back: the desktop leaves, the app stops and transcribes, and the
                # desktop rejoins the same call while that transcription is still running.
                time.sleep(float(args.rejoin_delay))
                joined = time.time() - 5
                desktop_join(url)
                for key, page in pages.items():
                    if not guest_in_call(page):
                        print(f"Rejoining guest {guests[key].get('display', key)}…", flush=True)
                        start_guest(page, url, guests[key].get("display", key))
                wait_for_guests(pages, admit=True)
                print(f"Round {round_index + 1}: {app_status_line()}", flush=True)
            frames = {}
            for key, page in pages.items():
                unmute = page.get_by_role("button", name=re.compile(
                    r"^(Unmute\b|Mikrofon wieder aktivieren)", re.I))
                if unmute.count():
                    unmute.first.click()
                frames[key] = guest_frames(page)
                if not frames[key]:
                    fail(f"Guest {key} has no injected microphone stream.")
            for event in truth["events"]:
                if event.get("via") == "guest":
                    data = base64.b64encode(Path(event["clip"]).read_bytes()).decode()
                    for frame in frames[event["speaker"]]:
                        frame.evaluate("([id, data]) => __meetingNotesGuest.load(id, data)",
                                       [event["clip"], data])
            for guest in frames.values():
                for frame in guest:
                    frame.evaluate("() => __meetingNotesGuest.prepare()")
            print(f"Everyone joined. Playing {scenario['name']} ({truth['duration']:.0f} s)…",
                  flush=True)
            time.sleep(float(args.settle))
            # Audio clocks keep overlaps intact even when UI automation takes time.
            stamp = time.strftime("%Y%m%d-%H%M%S")
            timing = []
            try:
                with microphone_playback(microphone, ffmpeg_index,
                                         directory / f"live-{stamp}.microphone.log") as (player, origin):
                    starts.append((joined, time.time() + origin - time.monotonic()
                                   + truth["duration"]))
                    for key, guest in frames.items():
                        plan = [{"id": event["clip"], "at": event["at"]}
                                for event in truth["events"] if event.get("speaker") == key]
                        for frame in guest:
                            frame.evaluate("(plan) => __meetingNotesGuest.schedule(plan)",
                                           {"delay": origin - time.monotonic(), "events": plan})
                    if time.monotonic() >= origin:
                        fail("Guest scheduling missed playback start; the machine is overloaded.")
                    for event in truth["events"]:
                        delay = origin + event["at"] - time.monotonic()
                        if delay > 0:
                            time.sleep(delay)
                        late = time.monotonic() - origin - event["at"]
                        timing.append({"at": event["at"], "late": round(late, 3)})
                        if late > 0.5:
                            fail(f"Playback control is {late:.1f}s late; this run cannot score overlaps.")
                        label = event.get("action") or f"{event['speaker']}: {event['text'][:60]}"
                        print(f"  [{event['at']:6.1f}s] {label}", flush=True)
                        if event.get("action"):
                            desktop_set_muted(event["action"] == "mute")
                    timeout = max(10, origin + truth["duration"] - time.monotonic() + 10)
                    if player.wait(timeout=timeout):
                        fail("Microphone playback failed.")
            finally:
                (directory / f"live-{stamp}.timing.json").write_text(json.dumps(timing, indent=2) + "\n")
            diagnostics = {key: [frame.evaluate("() => __meetingNotesGuest.audioStats()")
                                 for frame in guest] for key, guest in frames.items()}
            (directory / f"live-{stamp}.guests.json").write_text(
                json.dumps(diagnostics, indent=2) + "\n")
            if args.leave and not args.no_desktop and round_index + 1 < rounds:
                desktop_leave()
    print("Scenario finished.")
    if args.score:
        scored = []
        for start, expected_end in starts:
            scored.append(wait_and_score(start, truth, directory, float(args.score_timeout),
                                         expected_end=expected_end, skip=scored))
        if len(scored) > 1:
            report_back_to_back(scored)


def audiotoolbox_index(name):
    output = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "lavfi", "-i", "anullsrc", "-t", "0.01", "-f",
         "audiotoolbox", "-list_devices", "true", "-"], capture_output=True, text=True).stderr
    for line in output.splitlines():
        match = re.search(r"\[(\d+)\]\s+(.+?), ", line)
        if match and match[2].strip() == name:
            return int(match[1])
    fail(f"Audio device {name} not found.")


def meeting_records():
    """Meeting records (transcripts/<id>.json) written by the app, newest last."""
    records = []
    for path in TRANSCRIPTS.glob("*.json"):
        if not RECORD_NAME.match(path.name):
            continue
        try:
            record = json.loads(path.read_text())
        except ValueError:
            continue
        if record.get("schema_version") == 1 and record.get("id") == path.stem:
            records.append(record)
    return sorted(records, key=lambda record: record["started_at"])


RECORD_NAME = re.compile(r"^\d{8}T\d{6}Z(-\d+)?\.json$")


def record_started(record):
    from datetime import datetime
    return datetime.fromisoformat(record["started_at"]).timestamp()


def app_status_line():
    binary = APP / "Contents/MacOS/MeetingNotes"
    result = subprocess.run([binary, "status"], capture_output=True, text=True)
    return " ".join(result.stdout.split())


def check_recording_continuity(records, expected_end):
    """A scripted call must remain one recording through the final playback sample."""
    from datetime import datetime
    parts = [record for record in records if record_started(record) <= expected_end]
    if len(parts) > 1:
        fail("The meeting split into multiple recordings: "
             + ", ".join(record["id"] for record in parts))
    if parts and parts[0]["status"] == "complete":
        ended = datetime.fromisoformat(parts[0]["ended_at"]).timestamp()
        if ended < expected_end - 1:
            fail(f"Recording {parts[0]['id']} stopped {expected_end - ended:.1f}s "
                 "before playback finished.")


def wait_and_score(started, truth, directory, timeout, *, expected_end, skip=()):
    """Waits for the first meeting that started after `started` to be transcribed, scores it,
    and returns its id."""
    print("Waiting for Meeting Notes to finish the transcript…", flush=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        candidates = [record for record in meeting_records()
                      if started <= record_started(record) <= expected_end
                      and record["id"] not in skip]
        check_recording_continuity(candidates, expected_end)
        if candidates:
            record = candidates[0]
            if record["status"] == "complete" and record.get("transcript_file"):
                transcript = TRANSCRIPTS / record["transcript_file"]
                report = score(transcript, truth)
                report["meeting"] = record["id"]
                stamp = time.strftime("%Y%m%d-%H%M%S")
                (directory / f"live-{stamp}.report.json").write_text(
                    json.dumps(report, indent=2) + "\n")
                print(f"Meeting {record['id']} ({record.get('title') or 'untitled'}):")
                print_report(report)
                return record["id"]
            if record["status"] in ("failed", "interrupted"):
                fail(f"Meeting {record['id']} {record['status']}: {record.get('error')}")
        time.sleep(3)
    fail(app_error_since(started) or
         "No new transcript appeared. Is auto-record on, or did you start recording manually?")


def report_back_to_back(ids):
    """Shows from events.jsonl that each meeting started recording before the previous one's
    transcript was ready."""
    events = Path.home() / "Library/Logs/Meeting Notes/events.jsonl"
    times = {}
    for line in events.read_text(errors="replace").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("meeting") in ids:
            times.setdefault((entry["meeting"], entry["event"]), entry["time"])
    from datetime import datetime
    for previous, current in zip(ids, ids[1:]):
        ready = times.get((previous, "transcript.ready"))
        started = times.get((current, "recording.started"))
        if not ready or not started:
            print(f"Back to back: events for {previous} / {current} not found.")
            continue
        lead = datetime.fromisoformat(ready).timestamp() - datetime.fromisoformat(started).timestamp()
        verdict = "while the previous one was still being transcribed" if lead > 0 else \
            "after the previous transcript was ready (not back to back)"
        print(f"Back to back: {current} started recording {abs(lead):.0f} s {verdict} ({previous}).")


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
    command.add_argument("--tracks", action="store_true",
                         help="transcribe separate microphone and Teams tracks, as in a Teams call")
    command = commands.add_parser("score", help="score a transcript against a scenario")
    command.add_argument("scenario")
    command.add_argument("transcript")
    command.add_argument("--json", action="store_true")
    command = commands.add_parser(
        "replay", help="transcribe an archived live capture mixed and as separate tracks")
    command.add_argument("scenario")
    command.add_argument("capture", help="archived capture directory (see captureArchiveDirectory)")
    command.add_argument("--modes", default="mixed,separate")
    command.add_argument("--name", default="Me", help="local speaker label")
    command.add_argument("--echo", type=float, default=0.0,
                         help="add Teams playback to the microphone at this gain, e.g. 0.3")
    command.add_argument("--echo-delay", type=float, default=0.06,
                         help="acoustic delay of the simulated echo in seconds")
    command.add_argument("--echo-room", action="store_true",
                         help="simulate laptop speakers: reverb, saturation and drifting level")
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
    command.add_argument("--repeat", default=1,
                         help="play the scenario this many times back to back; the desktop "
                              "leaves and rejoins between rounds (needs --leave)")
    command.add_argument("--rejoin-delay", default=8,
                         help="seconds between leaving and rejoining with --repeat")
    command = commands.add_parser("config", help="show or save local settings")
    command.add_argument("--url", help="default Teams meeting link")
    args = parser.parse_args()
    handlers = {"setup": setup, "audio": audio, "render": render_command, "offline": offline,
                "score": score_command, "meeting": meeting, "config": config_command,
                "replay": replay}
    handlers[args.command](args)


if __name__ == "__main__":
    main()

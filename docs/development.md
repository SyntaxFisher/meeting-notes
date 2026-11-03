# Developing Meeting Notes

[Back to the product overview](../README.md)

## Build and verify

Apple silicon, macOS 26+, full Xcode, and Python 3 for the build tooling. `make build` (also the default), `make test`, `make lint`, `make install` (defaults to `/Applications`). Swift Package Manager builds the native helper; the menu-bar app retains its Makefile/swiftc build. Sparkle is fetched with a pinned checksum. A recent SDK path may be supplied using `SWIFT_FLAGS`. The local bundle is `build/local/Meeting Notes.app`; local builds are ad-hoc signed and disable the updater.

To update an existing installation, finish any recording or transcription, quit Meeting Notes, and run `make install` from the updated checkout. Builds use ad-hoc signing, which ties the app's code identity to that particular build, so macOS may require granting permissions again after an update. Public releases use a stable Developer ID signing identity to preserve code identity across updates. `make install` refuses to replace a running copy; prefer the released DMG for normal use. See [Apple's explanation of code identity and privacy permissions](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Fixture tests cover native audio conversion and format changes, owned callback buffers, microphone-only and mixed capture, mute, host timestamp alignment, failed-start cleanup, permission retry policy, retention, session recovery and filename collisions. Mock microphone engines cover Bluetooth-style 24 kHz to 48 kHz transitions, rebuilding after format errors, bounded retries, and cancelling recovery when stopped. Teams health checks cover active output without buffers and recovery after buffers return. Automated tests never start an audio device. Test an existing file with `build/MeetingNotesSmoke --transcribe /absolute/audio/path /absolute/path/to/MeetingTranscriber`. Append an expected speaker count (for example, `2`) to check that automatic detection returns that many labels; this does not force the detector's result. For live capture, use the [local Teams test environment](#local-teams-test-environment).

Logs: `~/Library/Logs/Meeting Notes/meeting-notes.log` and one rotated `meeting-notes.previous.log` (about 4 MB total). Logs include stages, detected speaker counts, failures, paths, Teams detection and retention deletions, but no audio or transcript contents. Audio diagnostics include device names and formats, Teams process/output status, and recovery attempts. A `capture.summary` entry for each selected source records buffer/frame counts, microphone mute counts, and peak sample levels before and after muting. These distinguish missing buffers from received silence; they do not establish system-audio authorization or identify speakers.

## Local Teams test environment

`scripts/devenv/devenv.py` simulates real meetings on this Mac. Teams desktop hosts a real meeting with a dummy account. Remote participants join as anonymous browser guests (headless Chromium via Playwright) whose microphones play synthetic speech. The local participant speaks through a virtual microphone. Scenarios are scripted, so every transcript can be scored against a known reference.

### Setup

1. `make devenv` installs ffmpeg, SwitchAudioSource, Teams, BlackHole 2ch and 16ch, and Playwright Chromium in `build/devenv/venv`. It restarts Core Audio if the BlackHole devices aren't loaded yet; this needs `sudo`.
2. Sign Teams in with the dev account. Create a reusable link under **Meet → Create a meeting link**, then save it with `python3 scripts/devenv/devenv.py config --url <link>`.
3. `python3 scripts/devenv/devenv.py audio on` sets the default input to BlackHole 2ch (the virtual microphone) and the default output to BlackHole 16ch (a silent speaker). The app's process tap still captures Teams playback. `audio off` restores the previous devices.
4. Build and open `build/local/Meeting Notes.app`, choose **Grant Permissions…**, and turn on **Auto-Record Teams Meetings**. Ad-hoc builds may need Accessibility granted again after a rebuild.

### Use

- `devenv.py render <scenario>` synthesizes each turn with macOS voices and writes `truth.json` and the ideal mix to `build/devenv/scenarios/<scenario>/`.
- `devenv.py offline <scenario>` transcribes that mix with the bundled `MeetingTranscriber`, without Teams or live capture, and scores it. Use it for quick transcription and diarization iterations.
- `devenv.py meeting <scenario> [--leave] [--score]` joins the meeting from Teams desktop (or reuses an existing meeting), starts one browser guest per remote speaker, and admits them from the lobby. It then plays every turn on schedule and toggles Teams mute where the scenario says so. With `--leave` it leaves at the end, so auto-record stops; with `--score` it also waits for the new transcript and scores it. Add `--headed` to watch the guests.
- `devenv.py score <scenario> <transcript>` scores any transcript.

Reports give the word error rate overall and per language, the detected and expected speaker counts, the share of words attributed to the right speaker, and how much speech said while muted leaked into the transcript.

### Scenarios

Scenarios live in `scripts/devenv/scenarios/*.json`. Each defines `speakers` (`via` is `mic` for the local participant or `guest`, plus a macOS `voice`, `lang`, and guest `display` name) and `steps`. A step is a turn (`speaker`, `text`, optional `voice`/`lang` override for code-switching, optional `audio` with a recording path), a `{"action": "mute"}` or `{"action": "unmute"}`, or a `{"pause": seconds}`. `gap` sets the pause before a step; a negative gap overlaps the previous turn. Personas such as Reed, Eddy or Sandy exist in several languages, so one speaker can switch languages with the same voice. List voices with `say -v '?'`.

- `quick-smoke`: 45 seconds, English and German, two speakers.
- `standup-de-en`: three speakers, code-switching, an overlap, and a sentence spoken while muted.
- `multilingual-panel`: five speakers in German, French, Spanish, Italian and English.

### Notes

- `scripts/devenv/TeamsControl.swift` (built to `build/devenv/teams-control`) presses Teams buttons through Accessibility, using the same enhanced-interface approach as `TeamsMuteReader`; `teams-control buttons` lists every control. `teams-control status-menu com.jona.meeting-notes [item]` drives the app's menu when the notch hides its icon.
- Guests open the Teams light-meetings page directly; the regular meeting link's launcher never finishes its SSO check in headless Chromium.
- Teams free has no lobby-bypass setting, so the host admits guests from the People pane.


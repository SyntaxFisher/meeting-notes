# Developing Meeting Notes

[Back to the product overview](../README.md)

## Build and verify

Apple silicon, macOS 26+, full Xcode, and Python 3.10 or later for the build tooling. `make build` (also the default), `make test`, `make lint`, `make install` (defaults to `/Applications`). Swift Package Manager builds the native helper; the menu-bar app retains its Makefile/swiftc build. Sparkle is fetched with a pinned checksum. A recent SDK path may be supplied using `SWIFT_FLAGS`. The local bundle is `build/local/Meeting Notes.app`; local builds are ad-hoc signed and disable the updater. For stable signing across local rebuilds, set `LOCAL_SIGN_IDENTITY` to an Apple Development certificate and provide a matching Mac development provisioning profile through `PROVISIONING_PROFILE` or `signing.provisioning_profile` in the local release configuration. See [signing setup](releasing.md#signing-setup).

To update an existing installation, finish any recording or transcription, quit Meeting Notes, and run `make install` from the updated checkout. Builds use ad-hoc signing, which ties the app's code identity to that particular build, so macOS may require granting permissions again after an update. Public releases use a stable Developer ID signing identity to preserve code identity across updates. `make install` refuses to replace a running copy; prefer the released DMG for normal use. See [Apple's explanation of code identity and privacy permissions](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Fixture tests cover audio conversion and recovery, transcription planning and speaker attribution, meeting lifecycle and retries, retention, configuration, library search, MCP/CLI operations, links and UI state. They use generated audio, mock capture engines and a substitute transcription helper; live capture uses the separate test environment below.

Test an existing file with `build/MeetingNotesSmoke --transcribe /absolute/audio/path /absolute/path/to/MeetingTranscriber`, or produce a full transcript and record with `"build/local/Meeting Notes.app/Contents/MacOS/MeetingNotes" transcribe <audio> <output.txt> [--capture <directory>]`. Append an expected speaker count (for example, `2`) to the first form to check that automatic detection returns that many labels. For live capture, use the [local Teams test environment](#local-teams-test-environment).

For isolated live checks, set `MEETING_NOTES_CONFIG_DIR` to a temporary config directory and `MEETING_NOTES_TEST_ROOT` to a separate fixture meetings folder. The normal library location is fixed at `~/Documents/meeting-notes`. Launch through `open -n --env MEETING_NOTES_CONFIG_DIR=/absolute/test/config --env MEETING_NOTES_TEST_ROOT=/absolute/test/meetings "build/local/Meeting Notes.app"` so macOS attributes privacy permissions to the app; pass that environment to CLI commands too. Quit the installed app only while idle, since both copies use the same control socket and bundle identity. Restore the installed app after checking the development build.

Natural-prompt MCP scenarios use `scripts/devenv/qa_fixtures.py`; see the QA section below.

Logs: `~/Library/Logs/Meeting Notes/meeting-notes.log` and one rotated `meeting-notes.previous.log` (about 4 MB total). Logs include stages, detected speaker counts, failures, paths, Teams detection and retention deletions, but no audio or transcript contents. Audio diagnostics include device names and formats, Teams process/output status, and recovery attempts. `capture.started` names the mode (`microphone-and-teams` or `microphone-and-device-audio`), and `recording.systemAudio` the Teams meeting state that chose it. A `capture.summary` entry for each selected source records buffer/frame counts, microphone mute counts, and peak sample levels before and after muting. These distinguish missing buffers from received silence; they do not establish system-audio authorization or identify speakers.

## Local Teams test environment

`scripts/devenv/devenv.py` simulates real meetings on this Mac. Teams desktop hosts a real meeting with a dummy account. Remote participants join as anonymous browser guests (headless Chromium via Playwright) whose microphones play synthetic speech. The local participant speaks through a virtual microphone. Scenarios are scripted, so every transcript can be scored against a known reference.

### Setup

1. `make devenv` installs ffmpeg, SwitchAudioSource, Teams, BlackHole 2ch and 16ch, and sets up Playwright with Chromium. It restarts Core Audio if the BlackHole devices aren't loaded yet; this needs `sudo`.
2. Sign Teams in with a separate test account, not a personal or work account. Create a reusable link under **Meet → Create a meeting link**, then save it with `python3 scripts/devenv/devenv.py config --url <link>`.
3. `python3 scripts/devenv/devenv.py audio on` sets the default input to BlackHole 2ch (the virtual microphone) and the default output to BlackHole 16ch (a silent speaker). The app's process tap still captures Teams playback. `audio off` restores the previous devices.
4. Build and open `build/local/Meeting Notes.app`, allow the permissions in the setup window, and turn on **Auto-record Teams meetings**. Ad-hoc builds may need Accessibility granted again after a rebuild.

### Use

- `devenv.py render <scenario>` synthesizes each turn with macOS voices and writes `truth.json` and the ideal mix to `build/devenv/scenarios/<scenario>/`.
- `devenv.py offline <scenario> [--tracks]` transcribes that mix like the app (`MeetingNotes transcribe` of `build/local`), without Teams or live capture, and scores the transcript. Without `--tracks` it is one mixed recording; with `--tracks` it builds a capture folder like a Teams call (your unmuted turns in `microphone.aac`, the guests in `system.aac`) and transcribes the tracks separately. Use it for quick transcription and diarization iterations.
- `devenv.py meeting <scenario> [--leave] [--score]` joins the meeting from Teams desktop (or reuses an existing meeting), starts one browser guest per remote speaker, and admits them from the lobby. It then plays every turn on schedule and toggles Teams mute where the scenario says so. With `--leave` it leaves at the end, so auto-record stops; with `--score` it also waits for the meeting's record to be complete and scores its transcript. Add `--headed` to watch the guests.
- `devenv.py meeting <scenario> --leave --score --repeat 2 [--rejoin-delay 8]` tests back-to-back meetings: the desktop leaves, waits, and rejoins the same call while the guests stay, so the next recording starts while the previous meeting is transcribing. Every meeting is scored, and the report says from `events.jsonl` how long before the previous transcript was ready the next recording started.
- `devenv.py score <scenario> <transcript>` scores any transcript.

`devenv.py offline solo --tracks` checks a solo call with a silent Teams track through the real transcription engine. It fails if microphone speech loses its local-speaker identity. Silence from other participants must not turn a known microphone track into anonymous mixed audio.

- `devenv.py replay <scenario> <capture directory>` transcribes an archived live capture twice, as one mixed recording and as separate microphone and Teams tracks, and compares the scores. `--echo 4` first adds a delayed, band-limited copy of the Teams track to the microphone at that gain, which simulates a call without headphones (`--echo-delay` sets the delay, 0.06 s by default).

Reports give the word error rate overall and per language, the detected and expected speaker counts, the share of words attributed to the right speaker (each label maps to the scripted speaker it transcribes most; "one label per person" allows each speaker only one label), the share of words that carry a name instead of a Speaker label and how many of those name the right person, and how much speech said while muted leaked into the transcript. Names count as right when the local label (`is_local_user` in the meeting record) covers the `mic` speaker or a label equals a guest's `display` name.

To keep the separate tracks of live recordings for `replay`, point the app at an archive folder before recording: `defaults write com.jona.meeting-notes captureArchiveDirectory ~/Library/Caches/meeting-notes-devenv/captures` (`defaults delete com.jona.meeting-notes captureArchiveDirectory` turns it off). The app copies each capture directory there after mixing. Setting `MEETING_NOTES_ECHO_FILTER=off` in the environment of `MeetingNotes transcribe` or `replay` disables the echo filter to measure its effect.

### Scenarios

Scenarios live in `scripts/devenv/scenarios/*.json`. Each defines `speakers` (`via` is `mic` for the local participant or `guest`, plus a macOS `voice`, `lang`, and guest `display` name) and `steps`. A step is a turn (`speaker`, `text`, optional `voice`/`lang` override for code-switching, optional `audio` with a recording path), a `{"action": "mute"}` or `{"action": "unmute"}`, or a `{"pause": seconds}`. `gap` sets the pause before a step; a negative gap overlaps the previous turn. Personas such as Reed, Eddy or Sandy exist in several languages, so one speaker can switch languages with the same voice. List voices with `say -v '?'`.

- `quick-smoke`: 45 seconds, English and German, two speakers.
- `standup-de-en`: three speakers, code-switching, an overlap, and a sentence spoken while muted.
- `planning-long`: about eight minutes, eight speakers in German and English, frequent half-second overlaps, short interjections, and a sentence spoken while muted.
- `multilingual-panel`: five speakers in German, French, Spanish, Italian and English.
- `produkt-sync`: three speakers in German and English, with an aside spoken while muted.
- `kundencall`: a short German customer call with one guest, meant to follow `produkt-sync` for back-to-back recording.

### Notes

- `scripts/devenv/TeamsControl.swift` (built to `build/devenv/teams-control`) presses Teams buttons through Accessibility, using the same enhanced-interface approach as `TeamsMuteReader`; `teams-control buttons` lists every control. `teams-control status-menu com.jona.meeting-notes` presses the app's status item, which opens the panel, and `open -a "Meeting Notes"` on the running app opens the Library.
- Guests open the Teams light-meetings page directly; the regular meeting link's launcher never finishes its SSO check in headless Chromium.
- Teams free has no lobby-bypass setting, so the host admits guests from the People pane. The pane stays open, so live recordings see the full participant roster; close it with `teams-control press "^Close participants pane" --meeting` to test tile-only detection.
- Teams can join a meeting muted; `meeting` unmutes after joining because scenarios start unmuted.
- Guests press Leave before their browser closes. Teams keeps guests that just disappear in the participant list for about a minute, so they would show up in the next run's roster.
- Live playback uses a continuous microphone track and pre-scheduled guest audio. The microphone playback includes muted test speech; the expected recording excludes it. Timing logs and guest WebRTC audio statistics are saved next to the scenario reports. A control delay over half a second aborts the run because it cannot reliably test overlap and mute timing.
- Device buffering and Teams' network path can shift live turns relative to the script. Check the captured tracks when evaluating short overlaps. Run the playback harness regression checks with `python3 -m unittest discover -s scripts/devenv -p 'test_*.py'`.


### Signed preview builds with updates

Normal local/ad-hoc builds disable Sparkle. To test the visible About update controls in a signed local build, use `ENABLE_UPDATER=1 LOCAL_SIGN_IDENTITY="<Apple signing identity>" PROVISIONING_PROFILE="/absolute/path/to/Matching.provisionprofile" make build`. This opt-in rejects ad-hoc signing. Release builds always enable Sparkle. Update checks and installation still wait while capture, transcription or permission setup is active.

### Natural-prompt MCP QA

`python3 scripts/devenv/qa_fixtures.py prepare <case>` creates a marked temporary library and returns a natural user request. Give agents only that request, root and the `tools`/`call` helper commands; keep fixture files and expected answers out of their context. `tools <root>` exposes the real MCP catalog/instructions, `call <root> <tool> '<json>'` runs the real server, and `audit <root>` reports calls/changes afterward. Ask each agent for usability feedback after its task. These cases simulate app control and delayed processing without capturing devices or touching real meetings. Use the live Teams environment separately for actual capture checks.

### Agent search evaluation

`python3 scripts/devenv/eval_search.py` asks Claude Code (Opus, Sonnet) and Codex nine questions about a synthetic two-hour steering meeting (`scripts/devenv/search-eval-meeting.json`) and records every MCP call through the real fixture server. Each answer hides behind wording the question does not use: synonyms, an English passage for a German question, a misheard product name, a vague description, a time window and a request for all decisions; two older meetings act as decoys. It prints per-run queries, missing facts and decoy use, then calls, empty searches, bytes read, time and Claude cost per agent. Narrow runs with `--agents`, `--cases` and `--repeat`; build the fixture binary with `make test` first. Keyword grading is a signal only; read the saved answers before drawing conclusions.

# Meeting Notes

Native macOS menu-bar recording and transcription. Records microphone and Microsoft Teams playback through ScreenCaptureKit, saves M4A, and transcribes locally using Parakeet TDT v3 multilingual plus FluidAudio offline speaker detection. No OBS, FluidVoice, server, Python, Node, or Codex is required at runtime.

## Use

Choose **Grant Permissions…** to request Microphone, then Accessibility, then Screen & System Audio Recording. Screen recording is requested only after the first two are granted, since it may require relaunching the app. After you grant Accessibility in Settings, the running app automatically requests Screen Recording once, within about three seconds; no second click is needed. Declining does not cause repeated automatic prompts. This continuation is armed only by **Grant Permissions…**, not at app launch. Each click retries missing permission requests; Meeting Notes does not also open Settings. Use the system prompt's own **Open System Settings** button when offered. ScreenCaptureKit's content-enumeration API requests screen/audio access without recording. If macOS omits the app from its permission list, use **+** in that pane to add `/Applications/Meeting Notes.app`. This action replaces **Start Recording** until all three permissions are granted; an orange circle with a black exclamation mark stays visible until then. Accessibility remains required even when Teams is closed or mute mirroring is disabled. Detecting Teams or its mute control is not required. Checks run every three seconds. Permission denials are logged, never sent as error notifications. An active recording always keeps **Stop & Transcribe** available, even if permission is revoked.

Choose **Start Recording**, then **Stop & Transcribe** when finished. Only audio is saved. If Teams is running when recording starts, ScreenCaptureKit includes its playback; otherwise recording is microphone-only without an error. Open Teams before starting if you want its playback included. Sounds from other apps are never substituted for missing Teams audio. The microphone can still pick up audible room sounds. Headphones avoid acoustic echo between Teams playback and the microphone.

The waveform pulses red at 75–100% opacity while recording. When **Mirror Teams Mute** detects a muted microphone during recording, a red pulsing slashed microphone replaces the waveform; unmuting restores it. The icon stays orange while preparing/transcribing and turns green for ten seconds after success. Actual errors use a red exclamation-mark icon, not the recording waveform. Only errors generate notifications; the latest replaces the previous error. A recording shorter than one minute with no detected speech is deleted silently instead of reporting an error; longer silent recordings still report one. **Retry Transcription** appears after failure. **Start Recording** remains available after a failed transcription; starting it abandons the retry but keeps the saved audio file. **Copy Last Transcript Path** and **Show in Finder** locate the latest output. Launch at Login is optional and off by default.

**Mirror Teams Mute** is enabled by default. When Accessibility can clearly detect Teams' “Unmute mic” control, Meeting Notes excludes microphone samples. Otherwise it records the microphone. During recording, the menu shows “Muted in Teams”, “Not muted in Teams”, or “No Teams meeting detected” as appropriate; uncertain states show “Teams mute status unavailable”. Detection changes are logged without notifications.

**Auto-Record Teams Meetings** is off by default. When enabled, Meeting Notes checks Teams every two seconds and starts recording as soon as a joined meeting is detected (a window with a **Leave** button), including a meeting already in progress when the option is turned on. It stops and transcribes about five seconds after the meeting is no longer detected or Teams quits. Only recordings it started are stopped automatically; recordings started with **Start Recording** stay under manual control. If you stop a recording, or a recording fails, while the meeting is still running, no new recording starts until that meeting ends. An automatic start follows the same rules as **Start Recording**, so it waits for permissions and for a running transcription to finish, and it abandons a pending **Retry Transcription** while keeping the saved audio. Turning the option off never stops an active recording.

After an ad-hoc-signed update, macOS may require removing and re-adding the installed app's permission entry or relaunching after a grant.

## Files and retention

Audio: `~/Documents/meeting-notes/audios/YYYYMMDDTHHMMSSZ.m4a`.
Transcript: `~/Documents/meeting-notes/transcripts/YYYYMMDDTHHMMSSZ.txt`.

Transcripts contain timestamps and anonymous Speaker 1/2/etc. labels. Voice labels are estimates within each recording, not participants' real identities; short clips and overlapping voices can reduce accuracy. There is no AI summary or cleanup.

Recordings are capped at 100,000,000 bytes and transcripts at 10,000,000,000 bytes, each folder with its own budget. At launch, before a recording, after audio is saved, and after transcription, the oldest timestamped files in each folder are permanently deleted until it fits, so a recording can be deleted while its transcript is kept. The newest recording and the newest transcript are always kept, even if one alone exceeds its budget. Existing timestamped MP3 recordings are included. Unrelated filenames, symlinks, active recording workspaces and the pending transcription are protected. Active/failed work can temporarily exceed the budget; it becomes eligible once transcription succeeds. Models and diagnostic logs are outside these budgets.

During capture, two compressed AAC/CAF tracks and their timing metadata are kept in a hidden `.timestamp.recording` directory. They are mixed into one M4A after Stop. On interruption, retry recovers readable tracks; an abrupt system crash can still damage an unfinished recording. Completed files are never overwritten and a partial TXT is never published.

## Native engine

The bundled Swift helper uses Parakeet TDT v3 and the upstream FluidAudio 0.17.1 offline diarizer. The release and resolved dependencies are pinned for reproducible builds. Models live in the shared `~/Library/Application Support/FluidAudio/Models` cache and download on first use if absent. Existing compatible cached models are reused. Transcription and speaker detection remain offline after model installation. Audio is processed in bounded slices after whole-file speaker detection to retain consistent speaker labels. The helper exits after each job to release model memory.

## Build and verify

Apple Silicon, macOS 15+, Swift toolchain. `make build`, `make test`, `make lint`, `make install` (defaults to `/Applications`). Swift Package Manager builds the native helper; the menu-bar app retains its Makefile/swiftc build. A recent SDK path may be supplied using `SWIFT_FLAGS`.

Fixture tests cover native audio conversion, mute, timestamp mixing, retention, session recovery and filename collisions. Test an existing file with `build/MeetingNotesSmoke --transcribe /absolute/audio/path /absolute/path/to/MeetingTranscriber`. Append an expected speaker count (for example, `2`) to check that automatic detection returns that many labels; this does not force the detector's result. Live capture requires separate approval.

Logs: `~/Library/Logs/Meeting Notes/meeting-notes.log` and one rotated `meeting-notes.previous.log` (about 4 MB total). Logs include stages, detected speaker counts, failures, paths, Teams detection and retention deletions, but no audio or transcript contents.

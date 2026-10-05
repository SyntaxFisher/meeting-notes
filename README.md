# Meeting Notes

Native macOS menu-bar recording and transcription. Records the microphone through AVAudioEngine and Microsoft Teams playback through a Core Audio process tap, saves M4A, and transcribes locally using Parakeet TDT v3 multilingual plus FluidAudio offline speaker detection. No OBS, FluidVoice, server, Python, Node, or Codex is required at runtime.

## Install

Download the DMG from the [latest release](https://github.com/SyntaxFisher/meeting-notes/releases/latest), open it, and drag **Meeting Notes** to **Applications**. Open it from Applications and choose **Grant Permissions…**. Requires **Apple silicon and macOS 26 or later**. Release downloads are signed with Developer ID, notarized by Apple, and include the native transcription helper. No developer tools are needed to run the app; models download on first transcription.

Signed releases check for updates hourly while running and online and download verified updates automatically. Updates normally install when you quit; Sparkle may offer a restart if the app stays open. **Check for Updates…** and **Automatic Updates** are in the menu. Checks and restarts wait while recording, preparing, transcribing, or granting permissions. Existing recordings, transcripts, models, and settings live outside the app bundle. Older ad-hoc installations need a one-time DMG installation and may need permission grants renewed.

## Use

Choose **Grant Permissions…** during initial setup. Requests run in this order: **Microphone → System Audio Recording → Accessibility**. The system-audio request is made before any meeting recording, even when Teams is closed. No audio is saved during permission setup. Denying microphone access or an explicit failure of the system-audio request stops the sequence before later permissions are requested. Grant Accessibility in System Settings when macOS prompts; the app checks it every three seconds. Once Microphone and Accessibility are granted and the system-audio setup step has run, **Start Recording** is available. Missing setup permissions show an orange warning. Accessibility remains required even when Teams is closed or mute mirroring is disabled.

No screen recording permission is requested, and no screen-sharing session is created. Public APIs do not expose a system-audio permission preflight. The app remembers that setup requested access for the current build; this is not treated as proof that macOS still allows it. An explicit Core Audio permission denial shows guidance to allow the app under **System Settings > Privacy & Security > Screen & System Audio Recording** and retry **Grant Permissions…**. Automatic recording remains blocked until setup is retried. Permission denials are logged without error notifications. An active recording always keeps **Stop & Transcribe** available. Normal macOS audio and microphone privacy indicators can still appear.

Choose **Start Recording**, then **Stop & Transcribe** when finished. Only audio is saved. If Teams is running when recording starts, the audio tap includes its playback; otherwise recording is microphone-only without an error. Open Teams before starting if you want its playback included. Sounds from other apps are never substituted for missing Teams audio. The microphone can still pick up audible room sounds. Headphones avoid acoustic echo between Teams playback and the microphone.

Capture opens the microphone before the Teams tap because a Bluetooth headset can change its playback format when its microphone opens. Microphone device changes rebuild the audio engine, with bounded retries while a device reconnects or changes format. The Teams tap follows changes to the default devices, Teams output devices, and device sample rates. Recovery can leave a short silent gap in the saved audio. If Teams has active audio output but no buffers reach its tap, the app attempts two tap restarts, then stops with an error and keeps captured audio available for **Retry Transcription**. Inactive Teams output does not trigger this check. Silent buffers are not treated as evidence of permission denial.

The waveform pulses red at 75–100% opacity while recording. When **Mirror Teams Mute** detects a muted microphone during recording, a red pulsing slashed microphone replaces the waveform; unmuting restores it. The icon stays orange while preparing/transcribing and turns green for ten seconds after success. Actual errors show a red circle with a black exclamation mark, matching the orange permission warning; hover it to read the error. Only errors generate notifications; the latest replaces the previous error. A recording shorter than one minute with no detected speech is deleted silently instead of reporting an error; longer silent recordings still report one. The first time the menu is opened after an error it offers **Retry Transcription** when failed audio is waiting. Closing that menu clears the error icon; unless Retry was chosen, the failed audio or interrupted recording is permanently deleted. **Copy Last Transcript Path** and **Show in Finder** locate the latest output. Launch at Login is optional and off by default.

**Mirror Teams Mute** is enabled by default and can be toggled at any time, including during recording. Disabling it immediately restores microphone capture; enabling it during recording applies the current Teams mute state. Mute detection supports the English and German Teams interfaces. When Accessibility can clearly detect Teams' “Unmute mic” or “Mikrofon wieder aktivieren” control, Meeting Notes excludes microphone samples. Otherwise it records the microphone. During recording with mirroring enabled, the menu shows “Muted in Teams”, “Not muted in Teams”, or “No Teams meeting detected” as appropriate; uncertain states show “Teams mute status unavailable”. Detection changes are logged without notifications.

**Auto-Record Teams Meetings** is off by default. When enabled, Meeting Notes checks Teams every two seconds and starts recording as soon as a joined meeting is detected (a window with a **Leave** or **Verlassen** button), including a meeting already in progress when the option is turned on. It stops and transcribes about five seconds after the meeting is no longer detected or Teams quits. Only recordings it started are stopped automatically; recordings started with **Start Recording** stay under manual control. If you stop a recording, or a recording fails, while the meeting is still running, no new recording starts until that meeting ends. An automatic start follows the same rules as **Start Recording**, so it waits for permissions and for a running transcription to finish, and it abandons a pending **Retry Transcription** while keeping the saved audio. Turning the option off never stops an active recording.

After an ad-hoc-signed update, macOS may require removing and re-adding the installed app's permission entry or relaunching after a grant.

## Files and retention

Audio: `~/Documents/meeting-notes/audios/YYYY-MM-DD HH.MM Meeting Title.m4a`.
Transcript: `~/Documents/meeting-notes/transcripts/YYYY-MM-DD HH.MM Meeting Title.txt`.

The timestamp is the local start time. Meeting Notes saves the known Teams meeting title when recording starts; if none is available yet, it saves the first usable title detected during the recording. It reads the title from the meeting window (the one with a **Leave** or **Verlassen** button) and removes the trailing ` | Microsoft Teams` or ` - Microsoft Teams`. A trailing ` | organization | account email` is also removed when Teams includes account information; separators within the meeting title are preserved. Generic titles such as "Calendar" are ignored, and without a title the name is just the timestamp. Recordings started in the same minute get `-2`, `-3`, and so on after the time. Older files named `YYYYMMDDTHHMMSSZ` (UTC) keep their names and are still covered by retention. `MeetingNotes --check-teams-mute` prints the detected meeting title without recording.

Transcripts contain timestamps and anonymous Speaker 1/2/etc. labels. Voice labels are estimates within each recording, not participants' real identities; short clips and overlapping voices can reduce accuracy. There is no AI summary or cleanup.

Recordings are capped at 100,000,000 bytes and transcripts at 10,000,000,000 bytes, each folder with its own budget. At launch, before a recording, after audio is saved, and after transcription, the oldest timestamped files in each folder are permanently deleted until it fits, so a recording can be deleted while its transcript is kept. The newest recording and the newest transcript are always kept, even if one alone exceeds its budget. Existing timestamped MP3 recordings are included. Unrelated filenames, symlinks, active recording workspaces and the pending transcription are protected. Active/failed work can temporarily exceed the budget; it becomes eligible once transcription succeeds. Models and diagnostic logs are outside these budgets.

During capture, two compressed AAC/CAF tracks and their timing metadata are kept in a hidden `.timestamp.recording` directory. They are mixed into one M4A after Stop. On interruption, retry recovers readable tracks; an abrupt system crash can still damage an unfinished recording. Completed files are never overwritten and a partial TXT is never published.

## Native engine

The bundled Swift helper uses Parakeet TDT v3 and the upstream FluidAudio 0.17.1 offline diarizer. The release and resolved dependencies are pinned for reproducible builds. Models live in the shared `~/Library/Application Support/FluidAudio/Models` cache and download on first use if absent. Existing compatible cached models are reused. Transcription and speaker detection remain offline after model installation. Audio is processed in bounded slices after whole-file speaker detection to retain consistent speaker labels. The helper exits after each job to release model memory.

## Build and verify

Apple silicon, macOS 26+, full Xcode, and Python 3 for the build tooling. `make build` (also the default), `make test`, `make lint`, `make install` (defaults to `/Applications`). Swift Package Manager builds the native helper; the menu-bar app retains its Makefile/swiftc build. Sparkle is fetched with a pinned checksum. A recent SDK path may be supplied using `SWIFT_FLAGS`. The local bundle is `build/local/Meeting Notes.app`; local builds are ad-hoc signed and disable the updater.

To update an existing installation, finish any recording or transcription, quit Meeting Notes, and run `make install` from the updated checkout. Builds use ad-hoc signing, which ties the app's code identity to that particular build, so macOS may require granting permissions again after an update. Public releases use a stable Developer ID signing identity to preserve code identity across updates. `make install` refuses to replace a running copy; prefer the released DMG for normal use. See [Apple's explanation of code identity and privacy permissions](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Fixture tests cover native audio conversion and format changes, owned callback buffers, microphone-only and mixed capture, mute, host timestamp alignment, failed-start cleanup, permission retry policy, retention, session recovery and filename collisions. Mock microphone engines cover Bluetooth-style 24 kHz to 48 kHz transitions, rebuilding after format errors, bounded retries, and cancelling recovery when stopped. Teams health checks cover active output without buffers and recovery after buffers return. Automated tests never start an audio device. Test an existing file with `build/MeetingNotesSmoke --transcribe /absolute/audio/path /absolute/path/to/MeetingTranscriber`. Append an expected speaker count (for example, `2`) to check that automatic detection returns that many labels; this does not force the detector's result. Live capture requires separate approval.

Logs: `~/Library/Logs/Meeting Notes/meeting-notes.log` and one rotated `meeting-notes.previous.log` (about 4 MB total). Logs include stages, detected speaker counts, failures, paths, Teams detection and retention deletions, but no audio or transcript contents. Audio diagnostics include device names and formats, Teams process/output status, and recovery attempts. A `capture.summary` entry for each selected source records buffer/frame counts, microphone mute counts, and peak sample levels before and after muting. These distinguish missing buffers from received silence; they do not establish system-audio authorization or identify speakers.

## Releasing

Agents should use the [release-meeting-notes skill](.agents/skills/release-meeting-notes/SKILL.md). The release workflow is `make release`, then `make publish`; this is Developer ID distribution through GitHub. Apple silicon/macOS 26 remains the supported platform. The bundled FluidAudio helper and resources ship inside the app.

### Signing setup

Full Xcode, Python 3, GitHub CLI access to `SyntaxFisher/meeting-notes`, and a valid Developer ID Application certificate with its private key in the login Keychain are required. The release script reads `~/.config/meeting-notes-release/config.json` (permissions `0600`):

```json
{
  "apple": {
    "key_id": "YOUR_API_KEY_ID",
    "issuer_id": "YOUR_ISSUER_ID",
    "key_path": "/absolute/private/path/AuthKey_KEYID.p8"
  },
  "signing": {
    "identity": "Developer ID Application: Your Name (TEAM_ID)"
  }
}
```

`NOTARY_CONFIG` can point to another local team config, and `SIGN_IDENTITY` overrides its identity. Alternatively, use `NOTARY_PROFILE` for saved notarytool credentials together with `SIGN_IDENTITY`. Keys and tokens stay outside the repository and release assets.

Sparkle's EdDSA key is stored in the login Keychain under account `com.jona.meeting-notes`. Its public key is in `Info.plist`; preserve both across releases. Securely back up the private key using `build/dependencies/sparkle-2.10.0/bin/generate_keys --account com.jona.meeting-notes -x /private/backup/path` and import it on another release Mac with `-f`. Do not generate a replacement as a workaround for Keychain access. macOS can request approval for `generate_appcast` or `sign_update`.

### Each release

1. Increase the three-part `CFBundleShortVersionString` and integer `CFBundleVersion` in `Info.plist`. Add `releases/<version>.md`.
2. Run `make lint`, `make test`, and `make build`. Tests use generated audio and mocks; live recording requires explicit approval.
3. Review, commit using a conventional commit, and push to `origin/main`.
4. Run `make release`. It builds arm64, signs the native helper and Sparkle components, signs the app with Hardened Runtime and the audio-input entitlement, notarizes/staples it, and creates the installer. The DMG has a fixed Finder layout, drag instruction, arrow, and Applications shortcut. The DMG is signed, notarized, stapled, and checked by Gatekeeper. Packaging tools are pinned with hashes in `scripts/dmg-requirements.txt` inside an isolated build environment.
5. Inspect `build/releases/<version>/manifest.json`, both notarization results (`Accepted`), app/DMG signatures, and the mounted installer. The script generates and verifies the signed update feed and checksums.
6. Run `make publish` when publication is authorized. It requires unchanged source/assets and `origin/main` at the manifest commit, tags that commit, uploads a draft, downloads and compares its asset hashes, then publishes it as Latest.

The three public assets are `Meeting-Notes-<version>-macOS-arm64.dmg`, `appcast.xml`, and `SHA256SUMS`. The app reads GitHub's `releases/latest/download/appcast.xml`; every release must include it. Earlier feed entries are retained and old assets must remain available. Never edit a signed feed or replace an existing public version. Failed builds remain available for diagnosis; inspect Apple's submission status before retrying, and move a failed version directory aside rather than overwriting a verified candidate.

Pinned dependencies: [Sparkle](https://sparkle-project.org/documentation/) 2.10.0 and FluidAudio 0.17.1 (`NativeTranscription/Package.resolved`). Both licenses are bundled. Preserve the bundle identifier and signing team. See [Sparkle update customization](https://sparkle-project.org/documentation/customization/) and [Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The installer follows the approved Idle Brew layout: plain grey, a heading and drag instruction, two icons, and an arrow, with no footer. Standard and Retina artwork is generated by `scripts/dmg-background.swift` and embedded in `Contents/Resources/InstallerBackground.tiff` before app signing. `scripts/dmg-layout.py` points Finder at that bundled artwork, leaving only Meeting Notes and Applications visible. Do not enable dmgbuild's `hide_extensions` setting: it adds FinderInfo to the signed bundle and invalidates its signature. Packaging verifies the copied app before completing the disk image.

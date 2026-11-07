# Meeting Notes usage reference

[Back to the product overview](../README.md)

## Setup and permissions

The setup window lists **Documents → Microphone → System Audio Recording → Accessibility**, each with an **Allowed** or **Not allowed** status. Use each row's **Allow** button to grant access; macOS may ask directly or open System Settings. Documents access is requested when the meetings folder is first read. You can also manage these permissions in **Settings > Permissions**.

No screen recording permission is requested and no screen-sharing session is created. macOS does not let apps preflight System Audio Recording, so the System Audio Recording "Allowed" label reflects a completed setup step; if Teams voices are missing, check **System Settings > Privacy & Security > Screen & System Audio Recording**. An explicit Core Audio denial blocks automatic recording until setup runs again. Accessibility detects Teams meetings, titles, participants and your mute state; automatic Teams recording requires it.

## The panel

Clicking the menu bar icon opens the panel. When the notch hides the icon, the panel opens at the top right of the screen. It shows:

- **Record control**: Ready while another meeting transcribes, or Recording with elapsed time and the meeting title. Hover to reveal a green play button or a red stop button, then click to record or stop and transcribe. A trash button appears on hover to discard a recording immediately. When permissions are missing, the header opens setup instead. Other reasons recording is unavailable appear here too.
- **Needs attention** (only when there is something): every failed, interrupted or untranscribed meeting with a short reason, **Retry** and **Discard**. The full error is in the tooltip and in the Library.
- **Last Meetings**: up to three recent meetings, including meetings still processing. Each row highlights on hover and opens the meeting in the Library. Processing rows show their progress and offer immediate cancel-and-discard. Background work stays visible while you record the next meeting. **Connect an Agent…** appears only while no agent is connected.
- **Open App** and **Settings** as full-width rows at the bottom. Use ⌘Q or the right-click menu to quit.

While macOS asks for access to the meetings folder (for example ~/Documents on first launch), the panel says *Waiting for access to Documents* and recording is unavailable; everything continues on its own once access is allowed. The command line and MCP keep answering meanwhile.

Right-clicking the icon offers Start/Stop, Library, Settings and Quit. Opening Meeting Notes again from Finder, Spotlight or the Dock opens the Library.

The icon stays red while recording, shows a red slashed microphone while muted in Teams, is orange while saving or transcribing, and returns to its normal color when finished. A red exclamation mark means a meeting needs attention.

## Recording

Auto-record is on by default. Meeting Notes checks Teams every two seconds and starts recording as soon as a joined meeting is detected (a window with a **Leave** or **Verlassen** button), including one already in progress. After Teams has been confirmed absent for about one second, it stops; the meeting is then saved and queued for transcription while you can already join the next one. Only recordings that auto-record started are stopped automatically. After you stop or discard a recording yourself, auto-record waits until you leave that meeting and join a new one. Turn it off in **Settings > General** or config.json.

The panel header, **File > Start Recording** in the Library, the command line, MCP, `meetingnotes://start` and Shortcuts start a manual recording. A new recording can start while earlier meetings are saving, queued or transcribing; their progress appears under **Last Meetings** while the header says Ready. The menu bar icon stays orange until processing finishes. Recording is refused while another recording runs, while permissions are missing or being set up, or while an update installs; every surface reports the same reason.

The app chooses audio automatically when recording starts and keeps that source until recording stops. During a detected Teams meeting, it records your microphone and Teams playback; notifications and music from other apps stay out. Outside Teams, a manual recording captures your microphone and everything the Mac plays except Meeting Notes itself. Only Teams meetings can start recording automatically, when enabled in Settings.

The app, CLI, MCP and Shortcuts all use this automatic choice; there is no source selector or remembered source preference. App and device audio use the same System Audio Recording permission. The record's `source` and `meeting-notes status` show which source a recording uses. Capture opens the microphone before the system audio tap because a Bluetooth headset can change its playback format when its microphone opens. Device and format changes rebuild the audio engine with bounded retries, which can leave a short silent gap. If audio plays but no buffers reach the tap, the app restarts the tap twice and then stops the recording, keeping what was captured.

**Mirror Teams mute** is on by default and can be toggled during a Teams recording. While Teams shows you as muted ("Unmute mic" or "Mikrofon wieder aktivieren"), your microphone is left out; when the state is unclear, the microphone is recorded. Mute mirroring, the Teams meeting title and participant roster apply only when recording Teams audio, selected automatically at recording start. Device-audio recordings do not inherit them. The Teams reads run on a background queue, so a slow Teams reply never delays the panel or your buttons.

**Discard Recording** stops the recording and moves what was captured to the Trash.

## Meeting lifecycle

Every meeting has one record, `transcripts/<id>.json`, created when recording starts. Its `status` moves through:

| Status | Meaning |
|---|---|
| `recording` | Audio is being captured. |
| `saving` | The tracks are being mixed into the saved audio. |
| `queued` | The audio is saved and waits for transcription. |
| `transcribing` | The transcription engine works on it; `stage` and `progress` show how far. |
| `complete` | The transcript is saved. |
| `failed` | Saving or transcription failed; `error` and `failed_at` say why and when. |
| `interrupted` | Meeting Notes quit while recording or saving. |
| `untranscribed` | Audio without a record or transcript, for example from an older version. Never written by the app. |

Transcription runs one meeting at a time in the order the meetings were queued. The queue is persistent: on launch, meetings left `transcribing` return to `queued` and continue, meetings left `saving` continue if their audio is complete and become `interrupted` otherwise, and meetings left `recording` become `interrupted`. Nothing is deleted on launch.

**Retry** on a failed, interrupted or untranscribed meeting queues it again; an interrupted recording is first saved from its captured tracks, which survive a crash, `kill -9` or power loss up to their last complete frame. **Discard** moves the meeting's audio, captured tracks and record to the Trash. Both act on one meeting; any number of meetings can need attention at once. CLI `retry` and `discard`, and MCP `retry_transcription`, can omit the meeting ID only when exactly one meeting needs attention. MCP `delete_meeting` requires an exact ID. Shortcuts provides recording and transcript-reading actions, not retry or discard. A recording under one minute with no detected speech is moved to the Trash automatically; a longer silent recording fails with "No speech was detected".

Quitting while recording or transcribing asks first. The recording is then stopped and saved, and queued meetings continue when Meeting Notes starts again. Updates wait until nothing is recording, saving, queued or transcribing and no permission setup runs.

## The Library

**Open App** in the panel opens the meeting library: meetings grouped into In Progress, Needs Attention and days, with search over titles, speaker names, Teams participants and transcript text. A meeting shows its date, length, speakers and the transcript as turns; clicking a passage seeks there while preserving play/pause state. Drag across transcript text to select and copy it. The header and player stay visible, shrinking when you scroll down and expanding when you scroll up. Speaker chips wrap onto additional lines. The player has play/pause (⌘P) and ±15 s (⌘[ / ⌘]).

Playback smoothly follows the current passage at the top until you scroll manually. When the current passage is off-screen, including while paused, **Jump to Now** points up or down toward it; clicking scrolls back and resumes following when playback runs. The current passage stays highlighted while paused, except at 0:00. Moving upward at the top edge always expands the header. Reduce Motion disables these animations. Right-click a passage to copy its text.

The gear button at the top right opens Settings directly.

- Right-click a finished transcript passage and choose **Edit Text…** to correct it with **Save** and **Cancel**. **Copy Passage** copies that passage. Clickable passages have a subtle hover highlight. If another editor or agent changes the meeting meanwhile, **Review Latest Version** keeps your draft and shows the current text before you save again.
- Clicking the speaker row opens **Edit Speakers** (⌘R), with Teams participants as name suggestions. Save names before choosing **Merge with…** for labels you know belong to the same person. Review the resulting name and confirm the merge.
- The **Copy Transcript** icon (⇧⌘C) copies the entire corrected transcript with timestamps and speaker names. Search, exports and agent reads use the same corrected version. Source links open the current passage with audio paused, and also work without a recording. Edits replace the transcript directly; there is no history, original copy or undo.
- Double-click the title to edit it directly. **Save** or Return applies it; **Cancel** or Escape keeps the previous title. Titles set here are protected from automatic agent naming.
- The trash button beside **Copy Transcript** asks for confirmation before moving the meeting to the Trash. **Retry Transcription** (⇧⌘T) remains available for failed work.
- **File > Start Recording** (⇧⌘R) and **Stop & Transcribe** (⌘.).

The app shows a Dock icon only while the Library is open. It does not request notification permission, send macOS notifications or show automatic status popups. The menu-bar icon and meeting rows show progress and errors.

Quiet system sounds mark the outcome of automatic and manual recordings: **Purr** when recording starts, **Frog** when it stops, **Pop** when you discard a recording or unfinished transcription, **Blow** when the transcript is ready, and **Basso** for errors. Deleting finished meetings and automatically removing short recordings without speech are silent.

## Settings

Recording, storage and agent preferences live in `~/.config/meeting-notes/config.json`; their Settings controls edit that file, and edits made by you or an agent apply within two seconds. An invalid file is never overwritten: the last valid settings stay in effect, the app reports the problem, and settings cannot be changed in the window until the file is fixed. Unknown keys produce warnings. The [automation guide](automation.md#settings-configjson) lists every key. Launch at login is managed by macOS; automatic updates and window state use app preferences outside this file.

- **General**: launch at login, auto-record, mirror Teams mute, and your name in transcripts.
- **Agents**: connect Codex, Claude Code or pi; copy the MCP setup command; allow agents to name untitled meetings, add summaries or correct recognition errors when working with meetings. Naming and summaries are on by default; corrections are off. Explicitly requested changes remain available when these preferences are off.
- **Permissions**: Documents, Microphone, System Audio Recording and Accessibility status, with controls to grant or manage access.
- **Advanced**: open the fixed meetings folder, delete all meetings, choose whether to keep audio, set its storage limit, and copy the automation help command.
- **About**: version, diagnostic log, update check and automatic-update controls for signed builds, GitHub and licenses.

## Transcripts and speaker names

A transcript starts with a short header: the title, the recording time, what each speaker label means and the participants Teams showed. Every turn follows as `[hh:mm:ss] Label: text`; header lines never start with `[`. Transcription itself does not summarize or rewrite the meeting. Connected agents can save a short summary and correct clear recognition errors according to your preferences or explicit requests. The summary appears below the meeting title in the Library.

```
Weekly Sync
Recorded 2026-11-05 15:28–15:30 (1 min 57 s)

Speakers:
- Jona Bihl: everything this Mac's microphone recorded; "Jona Bihl" in Teams
- Speaker 1, Speaker 2: remote voices in the Teams audio, told apart by sound; not matched to names

Participants in Teams:
- Jona Bihl (Organizer, this Mac), seen 00:00:00–00:01:55
- Anna Schmidt (Meeting guest, Unverified), seen 00:00:04–00:01:55

[00:00:22] Jona Bihl: Guten Morgen, lasst uns mit dem Daily anfangen.
```

- **Your name.** When a recording has separate microphone and call-audio tracks (Teams or device audio), the two tracks are transcribed separately and everything the microphone recorded carries your name: `localSpeakerName` from the settings, otherwise your Teams display name (from this meeting, or the last one Meeting Notes saw), otherwise your macOS full name, otherwise "Me". Muted passages are silence in the microphone track and never appear.
- **Remote speakers.** The call audio is split into voices by sound and labeled Speaker 1, Speaker 2, … in order of first appearance. Teams does not reveal who is speaking; for device audio the header says "remote voices in the device audio". A person who switches language or audio device can appear as two speakers.
- **One other participant.** When Teams listed exactly one participant besides you, all remote Teams speech carries that name. Device audio is never named after a Teams participant.
- **No remote speech.** Your microphone keeps its local-speaker identity even when the call-audio track is silent. Anonymous mixed transcription is used when separate capture tracks are unavailable.

Without headphones your microphone also picks up the Teams playback. Meeting Notes estimates the delay and level of that echo from the two tracks and drops microphone passages the Teams audio explains, so remote speech is not attributed to you. During double talk some remote words can still appear in your turn. People in the room who speak into your microphone are labeled with your name.

**Participants** are read from the Teams meeting window every two seconds while recording, without opening panes or changing the meeting. With the People pane open, Teams lists everyone with role and mute state; with it closed, only participants with a visible video tile and join notices. Detection is verified with the English Teams interface; German labels are recognized on a best-effort basis.

## Files and retention

Meetings are always stored in `~/Documents/meeting-notes`; the location is not configurable. **Settings > Advanced > Delete All Meetings…** moves all transcripts and recordings to the Trash after confirmation. It is unavailable while recording or transcription is running. Unrelated files are left alone.

```
~/Documents/meeting-notes/
├── audios/
│   ├── 2026-11-05 15.28 Weekly Sync.m4a
│   └── .2026-11-05 16.00.recording/      capture tracks while recording or until transcribed
└── transcripts/
    ├── 2026-11-05 15.28 Weekly Sync.txt  the current transcript
    ├── 2026-11-05 15.28.json             the meeting record
    └── 2026-11-05 15.28 Weekly Sync.summary.md   any other file starting with the id, such as your own notes
```

The **meeting id** is the local start time, `YYYY-MM-DD HH.MM`, with `-2`, `-3`, … for recordings started in the same minute. Every file of a meeting starts with it, so it stays stable when the Teams title is added. The title comes from the Teams meeting window (without the trailing "| Microsoft Teams" and account information); generic titles such as "Calendar" are ignored. Older files named `YYYYMMDDTHHMMSSZ` (UTC) are still listed and covered by retention.

The **record** (`schema_version` 1) holds the meeting's status, dates, file names, title, speakers, timed transcript segments and transcription details. Its `source` is `teams`, `device-audio`, `app:<bundleID>` or `microphone`. Edits update the record and the `.txt` transcript directly; `revision` protects against stale writers. Markdown is rendered on demand from the current title, corrected text and speaker assignments. See the [record reference](mcp-and-cli.md#the-meeting-record).

During capture, AAC tracks (`system.aac` for Teams, app or device audio and `microphone.aac`, self-framing ADTS streams) and their timing are kept in the hidden `.<id>.recording` folder. Microphone-only capture has only the microphone track. `capture.json` stores `systemAudio` as `teams`, `device-audio` or `app:<bundleID>`, or omits it for microphone-only capture; `participants.json` is collected only for Teams audio. Audio reaches the track files as it is encoded and is flushed every five seconds, so the tracks never need finalising: after a crash or `kill -9` they recover up to the last complete frame (well under a second lost), after a power loss up to the last few seconds. The folder stays until the transcript is saved, so the tracks can be transcribed separately, also on Retry. Completed recordings are never overwritten, and a partial transcript is never published. Requested transcript edits update the saved text directly.

**Retention.** Transcripts and their records are always kept until you delete a meeting yourself. Saved audio has a 10 GB limit by default, set in **Settings > Advanced** (`retention.audioBytes` in config.json). Lowering it shows what would be permanently deleted and asks for confirmation. The oldest recordings above the limit are removed; the newest recording and unfinished or failed meetings are protected. Unrelated files, symlinks and capture folders are ignored. Turn off **Keep audio recordings** to delete future audio after successful transcription. When switching it off, choose whether to keep existing recordings or permanently delete audio from completed meetings; transcripts and unfinished audio stay. The audio limit is hidden while this option is off.

## Command line

The app's executable is also a command-line tool: `"/Applications/Meeting Notes.app/Contents/MacOS/MeetingNotes" help` (or `meeting-notes help`; the app installs that command in `~/.local/bin` when it launches from an Applications folder). Reading and transcript-editing commands work without the app; recording commands start it. See [MCP server and command line](mcp-and-cli.md#command-line).

Diagnostics: `transcribe <audio> <out.txt> [--capture DIR] [--name N] [--title T]` transcribes a recording like the app and writes `<out.txt>` and `<out>.json` without overwriting; `teams-participants` prints the current meeting's roster; `check-teams-mute` prints the detected mute state and title.

## Native engine

The bundled Swift helper (`Contents/MacOS/MeetingTranscriber`) runs everything in-process: OpenAI Whisper large-v3-turbo through whisper.cpp 1.9.5 on the GPU (Metal), Silero VAD for voice activity, and the FluidAudio 0.17.1 offline diarizer for speakers. It returns timed segments as JSON; the app builds the transcript header, labels and record from them. The helper runs one meeting at a time and exits after each job to release model memory.

A job runs in stages, which the panel and the record's `stage` show: downloading the transcription model (first use only, with a progress bar), loading speaker models, identifying speakers, loading the transcription model, finding speech, detecting languages, then transcribing part *n* of *m* with a progress bar.

1. The diarizer separates remote voices in the Teams or device-audio track. Microphone speech is detected with VAD and echo filtering and keeps the local-speaker label. If separate tracks are unavailable, the diarizer works on the mixed recording.
2. Silero VAD identifies speech regions and excludes detected silence before transcription, reducing spurious text from silent audio.
3. Each stretch of speech gets its language detected independently to support multilingual meetings. Whisper is configured to transcribe, not translate.
4. Speech is packed in time order into parts of up to 28 seconds, split when the detected language changes. Each part is transcribed without carrying earlier text forward, reducing repeated recognition errors.
5. Word timestamps are mapped back to the original speech regions and speaker turns. Voice-activity boundaries help preserve short turns, but recognition and speaker attribution can still be wrong.

On an M2 with 8 GB, an 18-minute German lecture took about 2 minutes, and an hour of meetings in which the language changes every few sentences took 16 to 22 minutes. The time grows with the number of speaker turns and language changes, not with silence. The helper needs about 1.2 GB of memory. A new recording never waits for it: you can join the next meeting while earlier ones transcribe.

**Models.** The whisper model (`ggml-large-v3-turbo-q5_0.bin`, 574 MB) and the Silero VAD model (885 KB) download on first use from pinned revisions on Hugging Face into `~/Library/Application Support/Meeting Notes/Models` and are verified against their SHA-256 checksums before every use; a damaged file is downloaded again. The panel shows the download progress. The diarizer's models live in the shared `~/Library/Application Support/FluidAudio/Models` cache. Transcription is offline after the first download. Versions and licenses are listed in [third-party components](third-party-licenses.md).

In **Settings → Advanced → Storage**, turn off **Keep audio recordings** to delete audio as soon as its transcript has been successfully saved. Failed or interrupted work keeps its audio for retry. Switching it off asks whether to keep or delete existing completed recordings. Transcripts are always kept.

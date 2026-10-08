# Meeting Notes

Record a meeting from your menu bar and turn it into a timestamped transcript on your Mac. Meeting Notes captures your microphone and Microsoft Teams audio, then transcribes locally with speaker labels.

[Download the latest release](https://github.com/SyntaxFisher/meeting-notes/releases/latest)

## Features

- Start recording and transcribe when you finish, directly from the menu bar.
- Capture Teams playback alongside your microphone, or record your microphone on its own.
- Get timestamps and anonymous speaker labels in a plain-text transcript.
- Optionally start and stop recording automatically with Teams meetings.
- Mirror your Teams mute state to exclude your microphone while muted.

## Requirements

- An Apple silicon Mac running macOS 26 or later.
- Microphone, System Audio Recording, and Accessibility permissions.
- Internet access for the initial transcription model download. Transcription and speaker detection run locally after the models are installed.

## Install

1. Download the DMG from the [latest release](https://github.com/SyntaxFisher/meeting-notes/releases/latest).
2. Open it and drag **Meeting Notes** to **Applications**.
3. Open Meeting Notes from Applications.
4. Choose **Grant Permissions…** in its menu and follow the setup prompts.

The release app is signed with Developer ID and notarized by Apple. No developer tools are needed. Models download on your first transcription.

## Use

1. Open Teams before starting if you want to include its playback. Without Teams, the recording uses only your microphone.
2. Choose **Start Recording** in the Meeting Notes menu.
3. Choose **Stop & Transcribe** when you finish, or **Stop & Discard** to delete the recording immediately. Both actions pause auto-record until you leave the Teams meeting and join again.
4. Use **Show in Finder** or **Copy Last Transcript Path** to find the result.

Headphones help avoid echo between meeting playback and your microphone. Sounds from other apps are not captured in place of Teams audio, although your microphone can pick up sounds in the room.

The menu bar icon pulses red while recording, turns orange during processing, and briefly turns green when the transcript is ready.

If transcription fails, choose **Retry Transcription** the first time you open the menu after the error. Closing that menu without choosing Retry deletes the failed audio. Recordings shorter than one minute with no detected speech are also deleted automatically.

**Mirror Teams Mute** is on by default. When the app detects that you are muted in Teams, it excludes your microphone from the recording. Detection supports the English and German Teams interfaces. If mute status cannot be determined, the microphone is recorded.

**Auto-Record Teams Meetings** is off by default. Turn it on to record when you join a Teams meeting and transcribe shortly after you leave. Manually started recordings stay under your control. **Launch at Login** is also optional and off by default.

Transcripts include timestamps and labels such as **Speaker 1** and **Speaker 2**. These are estimates, not participants' names; short clips and overlapping voices can reduce accuracy. The app produces a transcript without an AI summary or cleanup.

## Privacy and permissions

Audio and transcripts are processed and saved on your Mac. Models download on first use, and release builds contact GitHub for updates.

Microphone permission allows voice capture. System Audio Recording allows Teams playback capture. Accessibility supports Teams meeting and mute detection and is required even for microphone-only recording. The app does not record video or request a screen-sharing session.

Files are saved under `~/Documents/meeting-notes/` in the `audios` and `transcripts` folders, named by recording time and the Teams meeting title when available.

**Older files are automatically deleted:** audio has a 100 MB storage budget and transcripts have a separate 10 GB budget. The newest recording and newest transcript are always kept, even if either exceeds its budget. Copy files you want to keep outside these folders. See [files and retention](docs/usage.md#files-and-retention) for details.

## Updates and uninstall

Release builds check for updates roughly hourly while running and download them automatically. Downloaded updates install and restart the app automatically once recording, transcription, and permission setup have finished. If auto-record is waiting for a Teams meeting you stopped recording to end, updates wait too, so restarting cannot resume that recording. Checks also wait while the app is busy; sleep and network availability can delay them. Use **Check for Updates…** or **Automatic Updates** in the menu to manage them.

To uninstall, finish recording or transcription, turn off **Launch at Login** if enabled, quit the app, and delete it from Applications. Your recordings and transcripts remain in `~/Documents/meeting-notes/`. Downloaded models remain in the shared `~/Library/Application Support/FluidAudio/Models` cache.

## Support

[Open an issue](https://github.com/SyntaxFisher/meeting-notes/issues/new) with your macOS version, Mac model, app version, and steps to reproduce the problem. Include whether Teams was open and which microphone or headset you used. Avoid posting private meeting audio or transcripts.

For permission troubleshooting, recording recovery, and detailed behavior, see the [usage reference](docs/usage.md).

## Development

See [build and verification instructions](docs/development.md) and the [release guide](docs/releasing.md).

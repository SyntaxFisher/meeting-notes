# Meeting Notes

Meeting Notes records your Microsoft Teams meetings from the menu bar and turns each one into a timestamped transcript on your Mac. Connect your coding agent once, and after a meeting you just ask it: "Summarize my last meeting."

[Download the latest release](https://github.com/SyntaxFisher/meeting-notes/releases/latest)

## How it works

1. Install the app and allow the permissions it asks for. Nothing else needs to be set up.
2. Join a Teams meeting. Meeting Notes starts recording on its own and transcribes the meeting a few seconds after you leave. You can go straight into your next meeting; earlier meetings wait in a queue.
3. Ask your agent (Codex, Claude Code or pi) about "my last meeting", or open the transcript from the menu bar.

Recording and transcription run on your Mac. Connected agents receive the transcript content you ask them to work with.

## Features

- **Automatic recording** of Teams meetings, including back-to-back meetings. Manual recording is one click away.
- **Local transcription** with timestamps by OpenAI Whisper large-v3-turbo, in German, English and the other languages Whisper knows, also when a meeting switches between them. Everything your microphone recorded carries your name, the Teams participant list is saved with the meeting, and a remote voice gets a name when Teams listed only one other participant.
- **Agent access** through a built-in MCP server. **Settings > Agents** connects Codex, Claude Code or pi with one click; `get_meeting` answers "my last meeting" in a single call.
- **Nothing is lost silently.** A failed or interrupted recording stays visible until you retry or discard it, even after a crash. Discarded and deleted meetings go to the Trash.
- **Optional extras** for people who want them: a Library window with search, playback from any timestamp and speaker renaming; a command-line tool; an event log, a `meetingnotes://` URL scheme and Shortcuts actions; a Settings window for recording, storage, agent preferences and updates.

## Requirements

- An Apple silicon Mac running macOS 26 or later.
- Documents, Microphone, System Audio Recording and Accessibility permissions.
- Internet access for the first transcription, which downloads the models (about 600 MB). Afterwards transcription runs offline.

## Install

1. Download the DMG from the [latest release](https://github.com/SyntaxFisher/meeting-notes/releases/latest).
2. Open it and drag **Meeting Notes** to **Applications**.
3. Open Meeting Notes. A short setup window asks for the permissions; it is the only window that ever opens by itself.

The release app is signed with Developer ID and notarized by Apple.

## Use

Click the menu bar icon to see the recording control, the last three meetings with transcription progress, and whether an agent is connected.

- **Recording**: auto-record starts when you join a Teams meeting and stops about a second after you leave. **Record** in the panel records anything else, for example a call in Zoom or Google Meet: without a Teams meeting it captures your microphone and everything the Mac plays. While recording, the panel offers **Stop & Transcribe** and **Discard Recording**.
- **Transcripts**: a quiet sound signals when a transcript is ready. **Last Meetings** and **Open App** in the panel open the meeting library, which also opens when you launch Meeting Notes again from Finder or Spotlight. The panel stays ready for a new recording while earlier meetings transcribe below.
- **Problems**: if a recording or transcription fails, the panel lists the meeting under **Needs attention** with **Retry** and **Discard**. Several meetings can wait there at once; each is handled on its own. Nothing is deleted until you choose Discard, and Discard moves the files to the Trash. Recordings under one minute without any speech are moved to the Trash automatically.

**Mirror Teams mute** (on by default) leaves your microphone out of the recording while you are muted in Teams. Headphones avoid echo between the meeting playback and your microphone.

In a Teams meeting, your microphone and the Teams audio are transcribed separately. Everything you said is labeled with your Teams display name once Meeting Notes has seen it (otherwise your macOS name; change it in **Settings > General**). Remote voices are labeled **Speaker 1**, **Speaker 2** and so on, told apart by sound; the transcript lists the participants Teams showed, so you or an agent can match them. A silent Teams track does not change your microphone label. When separate capture tracks are unavailable, the mixed recording uses anonymous speaker labels.

## Use with coding agents

Open **Settings > Agents** (or **Connect an Agent…** in the panel) and click **Connect…** next to Codex, Claude Code or pi. Meeting Notes shows the exact command it runs and then checks the result. Afterwards, ask your agent things like "Fass mein letztes Meeting zusammen", "What did we decide about the budget last week?" or "Record this call and send me the action items". See [using Meeting Notes with coding agents](docs/mcp-and-cli.md).

## Files and privacy

Meetings are saved in `~/Documents/meeting-notes/`: audio in `audios/`, and in `transcripts/` the plain-text transcript plus one JSON record per meeting with its status, speakers, summary, Teams participants and timed segments. Transcript corrections update the saved text directly; no original copy or edit history is retained.

**Transcripts are always kept.** Saved audio has a configurable 10 GB limit. The newest recording and unfinished or failed meetings are protected. See [files and retention](docs/usage.md#files-and-retention).

Documents access saves your meetings, Microphone captures your voice, System Audio Recording captures Teams playback (or all device audio for manual recordings outside Teams), and Accessibility detects Teams meetings, titles, participants and your mute state. Release builds contact GitHub for updates.

## Updates and uninstall

Release builds check for updates about every hour and install them only when nothing is recording, waiting for transcription or transcribing, and no permission setup is running. **Settings > About** has the controls.

To uninstall, quit Meeting Notes and delete it from Applications. Your meetings stay in `~/Documents/meeting-notes/`, the settings in `~/.config/meeting-notes/`, and the models in `~/Library/Application Support/Meeting Notes/Models` and `~/Library/Application Support/FluidAudio/Models`. If you connected an agent, remove it there too, for example with `codex mcp remove meeting-notes`.

## Support

[Open an issue](https://github.com/SyntaxFisher/meeting-notes/issues/new) with your macOS version, Mac model, app version and steps to reproduce the problem. Avoid posting private meeting audio or transcripts. For details, see the [usage reference](docs/usage.md) and [automation guide](docs/automation.md).

## Development

See [build and verification instructions](docs/development.md) and the [release guide](docs/releasing.md).

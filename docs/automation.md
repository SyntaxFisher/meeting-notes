# Automating Meeting Notes

[Back to the product overview](../README.md)

Everything here is optional; Meeting Notes works without any of it. For coding agents, the
[MCP server](mcp-and-cli.md) is usually all you need. This guide is for scripts, Shortcuts and Raycast. Everything is plain files and standard macOS mechanisms.

| What | Where | Direction |
| --- | --- | --- |
| Settings | `~/.config/meeting-notes/config.json` | read and write, applied live |
| Event log | `~/Library/Logs/Meeting Notes/events.jsonl` | the app appends, you tail |
| Commands | `meetingnotes://start` and friends, the [command line](mcp-and-cli.md#command-line) | you tell the app what to do |
| Shortcuts | Start Recording, Stop Recording and Transcribe, Get Latest Transcript | Shortcuts app, Spotlight, Siri |

**Settings > Advanced** changes storage settings and shows the command-line setup.
**Settings > General** shows problems with config.json.

## Settings: config.json

```json
{
  "$schema" : "https://raw.githubusercontent.com/SyntaxFisher/meeting-notes/main/docs/config.schema.json",
  "autoRecordTeamsMeetings" : true,
  "agentsMayNameMeetings" : true,
  "agentsMaySummarizeMeetings" : true,
  "agentsMayCorrectTranscripts" : false,
  "keepAudio" : true,
  "localSpeakerName" : null,
  "mirrorTeamsMute" : true,
  "playSounds" : true,
  "recognizeVoices" : true,
  "retention" : {
    "audioBytes" : 10000000000
  }
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `autoRecordTeamsMeetings` | `true` | Record when you join a Teams meeting, transcribe after you leave. |
| `agentsMayNameMeetings` | `true` | Request naming untitled meetings whenever agents read them. Existing titles stay unchanged. |
| `agentsMaySummarizeMeetings` | `true` | Require reading the whole transcript and saving a missing short summary, regardless of the current question. |
| `agentsMayCorrectTranscripts` | `false` | Require correcting every confidently identified recognition error in the transcript passages read. |
| `keepAudio` | `true` | Keep recordings after successful transcription. |
| `playSounds` | `true` | Play recording, transcription and error sounds. |
| `recognizeVoices` | `true` | Keep the voices of named remote speakers and name otherwise anonymous voices after them. Turning it off deletes the stored voices. |
| `mirrorTeamsMute` | `true` | Exclude the microphone while Teams shows you as muted, only when recording Teams audio. |
| `localSpeakerName` | `null` | Label for everything the microphone records. `null` uses your Teams display name once seen, otherwise your macOS name. No colons. |
| `retention.audioBytes` | `10000000000` | Budget of the `audios` folder; the oldest recordings above it are deleted. |

- The app creates the file with the defaults on first launch. Recording, storage and agent
  preferences are shared by the Settings window, the panel and the command line (`settings`). MCP's
  `get_status` reports recording, pending work and actionable problems.
  A change from the Settings window is applied on top of the file as it is at that moment, so
  edits an agent made a second earlier are kept.
- Changes apply within two seconds of saving, including while recording: mute mirroring switches
  immediately for Teams recordings, auto-record restarts its meeting detection. The audio budget
  applies right away; **Settings > Advanced** asks first when a lower limit deletes recordings. Transcripts are never removed automatically.
- Missing keys use their defaults. Unknown keys are ignored but reported (as `config.loaded`
  warnings in `events.jsonl`), which catches typos such as
  `autoRecord`.
- A file that is not valid JSON, or has a value of the wrong type or range, is rejected as a
  whole. The last valid settings stay in effect, the menu shows an error, `config.invalid` is
  logged, Settings shows the reason, and nothing in the app or the command line writes the file
  until it is fixed.
- `$schema` is accepted for editor validation; [`config.schema.json`](config.schema.json)
  describes the file.

```sh
# Turn auto-record off from a script or agent
meeting-notes settings auto-record off
# Keep up to 20 GB of recordings
meeting-notes settings recordings-limit 20GB
# or edit the file directly
jq '.autoRecordTeamsMeetings = false' ~/.config/meeting-notes/config.json > /tmp/c.json \
  && mv /tmp/c.json ~/.config/meeting-notes/config.json
```

Launch at login lives in **Settings > General** only: it is a macOS login item, not an app setting.
Automatic-update preferences and UI-only state such as window positions stay in the app's defaults.

## Event log: events.jsonl

One JSON object per line, appended as things happen:

```json
{"details":{"audioPath":"/Users/example/Documents/meeting-notes/audios/20261105T150207Z.m4a","automatic":true,"durationSeconds":74.2,"endedAt":"2026-11-05T16:03:21.410+01:00","id":"20261105T150207Z","speakers":["Speaker 1","Speaker 2"],"startedAt":"2026-11-05T16:02:07.180+01:00","title":"Weekly Sync","transcriptPath":"/Users/example/Documents/meeting-notes/transcripts/20261105T150207Z.txt"},"event":"transcript.ready","meeting":"20261105T150207Z","time":"2026-11-05T16:03:40.022+01:00"}
```

- `time`: local ISO 8601 timestamp. `event`: name below. `meeting`: the meeting id, or `null`.
- The **meeting id** is the UTC start time (`20261105T150207Z`, with `-2` for a second recording
  in the same second). It never changes, and every file of the meeting is named
  `<id>.<extension>`.
- When the file passes 1 MB it moves to `events.previous.jsonl` (replacing the previous one).

| Event | When | Extra details |
| --- | --- | --- |
| `app.started`, `app.quit` | App launch and quit | `build`, `config`, `meetingsRoot`, `socket`, `configError` |
| `recording.started` | Capture is running | |
| `recording.stopped` | Capture stopped; the audio is being saved | `error` when capture failed |
| `recording.discarded` | Discard Recording, or a recording under one minute without speech | `reason` |
| `recording.failed` | Nothing usable was saved (capture or mixing failed) | `error` |
| `recording.interrupted` | On launch, for a meeting left recording or saving | `previousStatus` |
| `transcription.queued` | The audio is saved and waits for transcription | `position`, `retry` |
| `transcription.started` | Transcription of this meeting begins | |
| `transcript.ready` | The transcript and record are complete | |
| `transcription.failed` | Transcription failed; the meeting needs attention | |
| `meeting.discarded` | An unfinished meeting was moved to the Trash | `trashed` |
| `meeting.deleted` | A finished meeting was moved to the Trash | `trashed` |
| `command.accepted`, `command.rejected` | Any surface ran a command: `panel`, `library`, `socket` (CLI, MCP), `url`, `shortcuts`, `auto-record` | `command`, `source`, `message`, `reason` |
| `config.loaded`, `config.invalid`, `config.changed` | config.json was read | `warnings`, `error`, `changed` |
| `agent.connected`, `agent.connectFailed` | Settings > Agents registered the MCP server | `agent`, `command` |
| `agent.removed`, `agent.removeFailed` | Settings > Agents removed the MCP server | `agent`, `command` |

Meeting events carry the meeting in `details`: `id`, `title`, `status`, `startedAt`,
`endedAt`, `durationSeconds`, `audioPath`, `transcriptPath`, `recordPath`, `speakers` (display
names), `localSpeaker`, `participants` (Teams), `automatic` and `error`; unknown values are `null`.
The meeting record (`recordPath`) has everything else, including the segments.

```sh
# Follow the app
tail -F ~/Library/Logs/Meeting\ Notes/events.jsonl | jq -c '{time, event, meeting}'

# Block until the next transcript is ready and print its id and path
meeting-notes wait
```

## Commands: meetingnotes://

```sh
open "meetingnotes://start?title=Design%20Review"
open meetingnotes://stop
```

| URL | Action |
| --- | --- |
| `meetingnotes://start[?title=<title>]` | Start recording |
| `meetingnotes://stop` | Stop and transcribe |
| `meetingnotes://reveal[?id=<meeting id>]` | Show the transcript in Finder |
| `https://meeting-notes.jonabihl.dev/meeting/<meeting id>[?p=<passage> or ?t=<seconds>]` | Open the meeting or passage with playback paused |
| `meetingnotes://meeting/<meeting id>[?p=<passage> or ?t=<seconds>]` | Existing native meeting links remain supported |

Meeting links are what the [MCP server and the command line](mcp-and-cli.md#navigation-and-source-links) return for
citing a passage, for example `https://meeting-notes.jonabihl.dev/meeting/20261105T141700Z?t=754.3`. The meeting id
is percent-encoded and must match exactly; `t` is seconds from the start of the recording, with
up to one decimal. The passage is the last segment starting at or before `t`, and playback
stays paused. Use `?p=s42` instead to address a passage ID exactly, including overlapping speech. A link without `t` or `p` just opens the meeting. A meeting that does not exist,
and a time past the end are explained in a short message in the Library. Passage links also work when audio has been deleted. Like a
file path, these links only work on the Mac that has the meeting.

There is no URL for discarding: any app on the Mac can open these URLs, so deleting work needs the
panel, the Library, the command line or MCP. Commands go through the same command layer as every
other surface and are refused for the same reasons. `open` cannot report back, so each command is
answered in `events.jsonl` with `command.accepted` or `command.rejected` and a `reason`. Encode
spaces as `%20`. If the app is not running, macOS launches it first. Browsers ask before opening
native-scheme URLs from a web page. HTTPS meeting links use Universal Links when the opening client supports them and macOS associates the domain with the app. URL commands are always enabled. Meeting links only navigate; they do not start playback or change stored content.

When several builds with the same bundle ID are registered (for example development builds),
macOS may pick any of them; `open -a "/path/to/Meeting Notes.app" "meetingnotes://…"` targets one.

## Shortcuts

Meeting Notes provides three App Intents, listed under Meeting Notes in the Shortcuts app and
available in Spotlight and to Siri:

- **Start Recording** and **Stop Recording and Transcribe** go through the command layer like
  every other surface and fail with the same reason when refused.
- **Get Latest Transcript** returns the text of the latest transcript for use in later actions.

The app is built with `swiftc`, not Xcode. `scripts/build.py` therefore performs Xcode's App
Intents step itself: it compiles the app in whole-module mode with `-emit-const-values-path` and
the protocol list Xcode uses, then runs `appintentsmetadataprocessor` to write
`Contents/Resources/Metadata.appintents`, from which macOS discovers the intents.

macOS (`linkd`) reads the intents from the copy of the app that Launch Services prefers for the
bundle ID, normally `/Applications/Meeting Notes.app`. A development build in `build/local` is
therefore only used by Shortcuts once it is installed with `make install`, or while the other
registered copies are unregistered with `lsregister -u`. The first run of each shortcut asks
whether it may run actions from Meeting Notes, and Get Latest Transcript asks once whether it may
output the text.

## Recipes

- **React to every meeting**: follow `events.jsonl` for `transcript.ready`, or run
  `meeting-notes wait` in a loop.
- **Wait for a meeting**: `meeting-notes wait <id>`, or `meeting-notes wait` for the next
  transcript; exit code 3 on timeout.
- **Record a call on demand**: `meeting-notes start --title "…"`, later `meeting-notes stop`, then
  `meeting-notes wait <id>`. From apps that can only open URLs, use `meetingnotes://start` and
  check `command.rejected` lines for refusals.
- **Clean up failures**: `meeting-notes list --status failed,interrupted`, then `retry` or
  `discard` each id.
- **Change a setting**: `meeting-notes settings …` or edit config.json, then check for
  `config.changed` (applied) or `config.invalid` (rejected, with the reason).

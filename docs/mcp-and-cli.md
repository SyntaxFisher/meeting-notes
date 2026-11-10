# Using Meeting Notes with coding agents

[Back to the product overview](../README.md)

Meeting Notes ships an MCP server and a command-line tool inside the app bundle. Once an agent is connected, "summarize my last meeting" (or "fass mein letztes Meeting zusammen") starts with one tool call; longer transcripts are read in pages. The agent never needs a file path. The server reads local meeting files and talks to the running app over a private socket. Your connected agent receives the passages it requests.

## Connect an agent

Open **Settings > Agents** (the panel shows **Connect an Agent…** until one is connected). Each installed agent among Codex / ChatGPT and Claude Code has a **Connect…** button; a connected one shows a green checkmark and **Remove…**, and one that is not installed just says so. Both buttons show the exact command, run it in a login shell after you confirm, and then check with the agent's own tool that the server is registered or gone. Errors are shown with the tool's output and a **Try Again…** button. While the tab is open, Meeting Notes checks the agents every five seconds, so changes made in a terminal show up by themselves. An agent counts as connected when it has an MCP server named `meeting-notes`, whatever command that server runs. Detection prefers the login shell’s CLI, then checks native and Homebrew install locations. Codex also uses the CLI bundled with ChatGPT Desktop; Claude Code can use the runtime downloaded by Claude Desktop after Code setup. Claude Code registration applies to local Code sessions; the Claude chat surface has its own MCP configuration.

One-click setup registers the app’s absolute executable path, so desktop clients work without shell configuration. On first launch from Applications, the app also installs `meeting-notes` in `~/.local/bin` and adds that directory to the zsh login profile for new terminal sessions. Manual terminal setup uses:

```sh
codex mcp add meeting-notes -- meeting-notes mcp
claude mcp add --scope user meeting-notes -- meeting-notes mcp
```

**Remove…** runs:

```sh
codex mcp remove meeting-notes
claude mcp remove --scope user meeting-notes
```

For another agent, add a stdio MCP server named `meeting-notes` that runs `meeting-notes mcp` (the [command](#command-line) the app installs in `~/.local/bin`). For desktop clients with a separate PATH, use the app’s absolute executable path followed by `mcp`.

From a terminal: `meeting-notes agent-setup` shows which agents are connected and their commands, and `meeting-notes agent-setup --connect codex` (or `claude`) runs one. The commands honour `CODEX_HOME` and `CLAUDE_CONFIG_DIR`.

Then ask, for example:

- "Fass mein letztes Meeting zusammen."
- "What did we decide about the release date in this week's meetings?"
- "Record the meeting I'm joining now; when I say it's over, stop and send me the action items."
- "Speaker 2 in the latest meeting is Grace; name her and draft the follow-up email."

## MCP tools

Start with `get_meeting` for the newest meeting. MCP responses are compact text with Markdown-compatible links; there is no format selector or duplicated JSON payload. The server implements MCP 2025-06-18 over stdio and accepts 2025-03-26 and 2024-11-05 clients.

| Tool | Parameters | Purpose |
| --- | --- | --- |
| `get_meeting` | Optional `meeting_id`, `passage`, `at`, `context`, or `cursor` alone | Newest meeting by default, or ID/unique title. Reads full pages or nearby passages. |
| `open_meeting` | Optional `meeting_id` (default latest), `passage` or `at` | Show the meeting or passage in the app, paused, only when the user asks. |
| `list_meetings` | Optional `since`, `until`, `status`, `limit`, or `cursor` alone | Browse newest first, with no transcript search. |
| `search_meetings` | `queries` (1–30 alternatives); optional `meeting_id`, `since`, `until`, `limit`, or `cursor` alone | Keyword search across titles, people and transcripts, grouped by meeting with passage excerpts. A passage matches any query. |
| `get_status` | None | Recording, pending work, failures and blocked-start reasons. |
| `start_recording` | Optional `title` | Automatic Teams/device audio capture, including microphone. |
| `stop_recording` | None | Stop and transcribe. |
| `retry_meeting` | Optional `meeting_id` | Retry; ID can be omitted only if one meeting needs attention. |
| `delete_meeting` | Exact `meeting_id` | Stop/cancel if necessary, then move any meeting and its files to Trash. |
| `edit_transcript` | Exact `meeting_id`, `revision`, `changes: [{segment_id, text}]` | Atomically replace 1–100 full passages. |
| `merge_speakers` | Exact `meeting_id`, `revision`, `keep`, `merge`, optional `name` | Combine labels confirmed to represent the same person. |
| `update_meeting` | Exact `meeting_id`, `revision`, `topic`, `summary` and/or `speakers: {label: name}` | Name an untitled meeting, save a short summary, or rename speakers; empty speaker name clears the assignment. |

`get_meeting` waits up to 20 seconds for queued/saving/transcribing work, but immediately reports a recording in progress. If the newest meeting is not ready or failed, it reports that meeting; it never substitutes an older completed transcript. Read again later or retry a failed meeting when requested.

Dates accept ISO date/timestamp, `today`, `yesterday`, or ages such as `7d`. `since` is inclusive and `until` exclusive. List status accepts comma-separated `recording`, `saving`, `queued`, `transcribing`, `complete`, `failed`, `interrupted`, `untranscribed`. List/search default to 10 results, at most 50.

## Navigation and source links

Provide the meeting URL by default. Call `open_meeting` only when the user explicitly asks to open a meeting or passage. If the user cannot find it, the agent may offer to open it and must wait for acceptance. It opens the native app directly, launching it if needed, without a browser and without starting playback. Omit `passage` and `at` for the whole meeting. Reads and summaries never open the app on their own. MCP returns HTTPS Universal Links on `meeting-notes.jonabihl.dev`. Existing `meetingnotes://meeting/` links remain supported; there is no localhost listener.

Each meeting supplies its `url` once. Passages have stable short IDs (`s1`, `s2`, …) and timestamps. Cite a passage by appending `?p=<passage ID>` to that URL:

```text
url: https://meeting-notes.jonabihl.dev/meeting/20261105T141700Z
s42 00:12:34 Speaker 1: We ship on the 14th.
```

Citation: `[00:12:34](https://meeting-notes.jonabihl.dev/meeting/20261105T141700Z?p=s42)`.

For meeting references, use the base meeting URL unchanged, without `?p=` or `?t=`. Passage links are for specific transcript evidence or an explicitly requested location.

The app resolves the passage ID exactly, including overlapping speech, without starting playback. Links work even without stored audio. Time links (`?t=754.3`) also remain available. Meeting and passage links refer to private local data even though they use HTTPS. Treat them and local file paths as private local references; do not fetch meeting URLs as webpages. They may appear only in direct chat answers to the user, never in documents, saved summaries, files, emails or other shareable output—even drafts for the user—and must never be disclosed to other people or external services.

Meeting details supply `recording_path` while the audio file exists, for tasks that need the audio itself. Storage/config internals are not exposed. CLI exports can still include full JSON and Markdown.

Search is literal, so the agent passes synonyms, word stems and both meeting languages as alternative `queries` in one call, for example `["kost", "budget", "cost"]`. Within one query, all words must match; a passage matches when any query does. Words match from their start, so `kost` finds "Kosten" and "kostet" but "Eskalation" does not find "eskaliert". For everything said about a topic, or when searches find little, the server instructions tell agents to read the whole meeting instead of guessing more keywords: things said in other words, misheard terms and the other language never match. A two-hour meeting is only a few pages.

For a specific search hit, use `get_meeting` with its `meeting_id` and `passage`. For a time, use `at` with seconds or `HH:MM:SS`. Both return two neighboring passages on each side by default; `context` accepts 0–10. The response indicates its position in the complete transcript and lets the agent continue forward.

Transcript pages contain up to 12,000 text characters and 100 passages. Whole passages stay together where possible. Exceptionally large passages split with a clear partial marker; read all parts before replacing one. Continue by passing the returned `next_cursor` as `cursor` alone to the same tool. Cursors carry the queries, position and version so the agent does not manage offsets. Changed transcripts/results reject stale continuations rather than mix versions. Absence of a cursor means the result is complete.

## Naming, summaries and corrections

The agent settings add a required-follow-up section at the end of each completed, nonempty transcript page, including continuation and targeted passage/time reads. The section identifies the enabled settings as the user's standing request, independent of the current question. These instructions appear only in tool responses, not MCP server instructions or tool descriptions. A client can still prioritize conflicting instructions or refuse a write; the server cannot guarantee that an external agent performs the follow-up.

**Settings > Agents > Allow agents to name meetings** is on by default. Only meetings without a title receive a naming request. The agent saves a concrete title of 3–7 words in the meeting's language, without a date. Existing titles receive no naming reminder and stay unchanged. Disabling the setting removes the automatic request; naming explicitly requested by the user remains available.

**Allow agents to summarize meetings** is on by default. Meetings without a saved summary receive a request to read the entire transcript and save `summary` through `update_meeting`: 1–3 factual sentences in the meeting's language, one short sentence for brief meetings. This includes finishing all transcript pages even when the user's question targets a single passage. Once a summary exists, the request disappears. The summary appears below the selected meeting's title and in meeting details. Summaries are limited to 1,000 characters and saved with the same revision checks as other edits. Transcript corrections and speaker changes clear outdated summaries; mutation replies repeat any outstanding naming/summary requests with the new revision. Disabling the setting removes the automatic request; explicit summary requests remain available.

**Allow agents to correct transcription errors** is off by default. When enabled, each transcript page requests correction of every confidently identified recognition mistake in the passages read. The agent must preserve meaning, avoid stylistic rewriting and leave uncertain names, numbers and wording unchanged. Finish reading before editing, batch corrections to keep continuation cursors usable, then save a missing title and summary together using the resulting revision. Corrections explicitly requested by the user remain available regardless of this setting. Agents briefly mention changes in their answer. There is no local language model.

Text edits, speaker changes and titles update the record and overwrite the transcript. No original copy, history or undo is retained. Passage IDs and timing remain fixed. Read before editing, use the exact ID and current revision, and review again after a conflict. Each edit is atomic; invalid or stale changes leave the meeting untouched. Merge only labels known to represent one person, specifying `name` when assigned names disagree.

```json
{"meeting_id":"20261105T141700Z","revision":0,"changes":[{"segment_id":"s4","text":"We ship on the 14th."}]}
```

Mutation replies provide the resulting revision and relevant changed title/speakers. Recording actions return a concise result and meeting ID. Errors provide actionable text rather than internal status dumps.

## Command line

The app installs a `meeting-notes` command in `~/.local/bin` whenever it launches from an Applications folder, so installing or updating the app keeps the command current. A file of that name that is not Meeting Notes' own is left alone; then call the executable inside the app bundle.

```sh
meeting-notes show latest                 # Markdown with front matter
meeting-notes list --since 7d
meeting-notes list --status failed,interrupted
meeting-notes search budget thursday
meeting-notes rename-speaker latest 2 "Grace"
meeting-notes start --title "Design review"
meeting-notes stop
meeting-notes wait                        # the next transcript; or: wait <id>
meeting-notes retry 20261105T141700Z
meeting-notes discard 20261105T141700Z  # moves it to the Trash
meeting-notes delete 20261105T141700Z   # any meeting, cancelling active work and moving it to the Trash
meeting-notes settings auto-record off local-name "Jona B."
meeting-notes settings sounds off
meeting-notes settings recordings-limit 20GB
meeting-notes status --json
```

Every command accepts `--json`. `list`, `show`, `search`, `rename-speaker`, `set-title --meeting` and the editing commands below work while the app is closed. `status` works too and then reads the files. `start`, `stop`, `retry`, `discard`, `delete` and `set-title` for the recording in progress go through the running app and launch it when needed. `settings` changes config.json through the app, or directly when it is not running; without arguments it prints the supported settings. Storage limits take bytes or a size such as `20GB` (decimal units). Lowering the audio limit removes the oldest eligible recordings; transcripts are always kept. The meetings folder is fixed. Exit codes: 0 success, 1 error, 2 usage error, 3 `wait` timed out.

`show --json` includes the current `revision`, speaker labels and each passage's `segment_id`; it exports the complete current transcript. `edit-text` and `merge-speakers` require the exact meeting id and `--revision` from a read. For example, substituting the IDs and revisions returned for your meeting:

```sh
meeting-notes show latest --json
meeting-notes edit-text 20261105T141700Z s4 "We ship on the 14th." --revision 0 --json
meeting-notes merge-speakers 20261105T141700Z "Speaker 1" "Speaker 2" --name Ada --revision 1 --json
```


`wait <id>` follows that meeting through recording, saving, the queue and transcription. `wait` without an id returns the next transcript that finishes: of the meetings in progress when it starts, or of the next meeting that starts. Both fail when the meeting fails or is discarded.

## Meeting ids

A meeting's id is its UTC start time, for example `20261105T141700Z` (with `-2` for a second recording in the same second), and every file of the meeting is named `<id>.<extension>`. It is fixed when recording starts and never changes, also when its title changes. CLI reads accept the id, a unique id prefix (`20261105`), a unique title fragment (`weekly`) or `latest` for the newest completed meeting. MCP `get_meeting` and `open_meeting` use the newest meeting regardless of status when the ID is omitted or `latest`; they never substitute an older completed meeting. MCP editing tools and CLI `edit-text` and `merge-speakers` require the exact id returned by a read, together with its revision.

## The meeting record

Each meeting has one record, `transcripts/<id>.json`, the single source of truth for its status and metadata. It is created when recording starts and updated at every step:

```json
{
  "schema_version": 1,
  "id": "20261105T141700Z",
  "title": "Weekly Sync",
  "started_at": "2026-11-05T15:17:00+01:00",
  "ended_at": "2026-11-05T15:18:08+01:00",
  "duration_seconds": 68.4,
  "source": "teams",
  "trigger": "automatic",
  "status": "complete",
  "revision": 0,
  "audio_file": "20261105T141700Z.m4a",
  "transcript_file": "20261105T141700Z.txt",
  "speakers": [
    { "label": "Jona Bihl", "is_local_user": true, "identity": "local-user", "source": "microphone", "participant": "Jona Bihl", "turns": 4, "seconds": 31.2 },
    { "label": "Speaker 1", "name": "Ada", "is_local_user": false, "identity": "unidentified", "source": "teams", "turns": 3, "seconds": 22.0 }
  ],
  "participants": { "participants": [ { "name": "Jona Bihl", "isLocal": true, "role": "Organizer", "firstSeen": 0, "lastSeen": 66, "sources": ["roster"] } ], "sawFullRoster": true },
  "transcription": { "mode": "separate-tracks", "engine": "whisper large-v3-turbo (whisper.cpp 1.9.5, Silero VAD) with FluidAudio offline diarization" },
  "segments": [ { "start": 20.1, "end": 25.9, "speaker": "Jona Bihl", "text": "Hi, can you hear me?" } ],
  "updated_at": "2026-11-05T15:18:20+01:00"
}
```

- `status` is one of `recording`, `saving`, `queued`, `transcribing` (with `stage` and `progress`), `complete`, `failed` or `interrupted` (with `error` and `failed_at`); `untranscribed` marks audio an older version saved but never transcribed. See the [lifecycle](usage.md#meeting-lifecycle).
- `source` is fixed at recording start: `teams`, `device-audio`, `app:<bundleID>` or `microphone`. Automatic uses Teams during a detected Teams meeting, otherwise device audio; auto-record always uses Teams. `meeting-notes status` shows the active source. See [recording sources](usage.md#recording).
- Speaker `identity` is `local-user`, `sole-remote-participant`, `teams-speaker` (matched using Teams’ active-speaker readings), or `unidentified`. Names are estimates and can be corrected.
- `segments` and `speakers` describe the current transcript. `segments[].speaker` is a speaker label; `speakers[].name` is its assigned name. After a merge, the affected passages use the surviving label. `is_local_user` is identity metadata, not proof that every microphone voice belongs to one person.
- Edits overwrite the `.txt` transcript and update the record. `revision` increases with each effective change. File names are relative to `audios/` and `transcripts/`.
- Transcripts from older versions get a record when their files are [renamed to the current scheme](usage.md#files-and-retention).
- CLI `show` renders Markdown on demand from the current corrected text and speaker assignments. MCP `get_meeting` returns a compact text view with passage IDs and a meeting URL; both read the same saved transcript.

## Control socket

The running app listens on `~/Library/Application Support/Meeting Notes/control.sock` (mode 0600, peer user checked). Each connection carries one JSON request line and gets one JSON response line with `ok`, `message`, `meeting_id` and the full `status`. Commands: `status`, `start`, `stop`, `retry`, `discard`, `delete`, `open_meeting`, `set_title`, `rename_speakers`, `set_settings`. They go through the same command layer as the panel, the URL scheme and Shortcuts, so every surface applies the same checks and reports the same reasons. Prefer the CLI or MCP; the socket may change between versions.

## Limits

- Recording requires macOS permissions. MCP `get_status` explains when starting is blocked; permission setup is available in the app.
- Search matches keywords at word starts, ignoring case and accents. It is not semantic and does not translate; agents read the meeting when keywords are not enough.
- Remote speaker labels are estimates per recording. Agents should name speakers only on clear evidence and say so.
- The first time the CLI or MCP server reads `~/Documents/meeting-notes`, macOS may ask the app hosting the agent for access to the Documents folder.

Source links select and scroll to the passage without starting playback, including for meetings without stored audio. The `keepAudio` configuration setting defaults to `true`; when `false`, audio is deleted after successful transcription, while failed work remains available for retry.

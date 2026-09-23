# Agent instructions

- This is a small native Swift macOS menu-bar app. Keep it Makefile-based, with no Xcode project, package manager, or runtime dependency on Codex or Node.
- Do not start OBS recording or join a call during automated tests. An end-to-end recording test requires the user's separate approval.
- Preserve existing MP3s and transcripts; never overwrite a completed file.
- Run `make lint` before any commit.

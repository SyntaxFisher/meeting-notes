# Agent instructions

- This is a native Swift macOS menu-bar app. Keep the Makefile; Swift Package Manager builds the bundled FluidAudio helper. No OBS, FluidVoice, Codex, or Node runtime dependency.
- Do not record microphone or system audio or join a call during automated tests. A live recording test requires separate user approval. Existing files and generated fixtures may be processed locally.
- Never overwrite a completed recording or transcript. Retention removes the oldest recordings above 100 MB and the oldest transcripts above 10 GB, always keeping the newest of each and protecting pending work.
- Run `make lint` before any commit.
- For signed DMG preparation/publication, use `.agents/skills/release-meeting-notes/SKILL.md` and the README release workflow (`make release`, then `make publish`).
- Preserve bundle ID `com.jona.meeting-notes`, the Sparkle signing key, and the Apple signing team. Release credentials stay in local configuration/Keychain.
- Release builds enable Sparkle; ad-hoc builds disable it. Updates must not interrupt recording, transcription, or permission setup.

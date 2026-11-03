# Agent instructions

- This is a native Swift macOS menu-bar app. Keep the Makefile; Swift Package Manager builds the bundled FluidAudio helper. No OBS, FluidVoice, Codex, or Node runtime dependency.
- For live end-to-end checks, use the local Teams test environment in `scripts/devenv` (see `docs/development.md`): a dummy Teams account, virtual audio devices and synthetic speech. `make test` stays device-free.
- Never overwrite a completed recording or transcript. Retention removes the oldest recordings above 100 MB and the oldest transcripts above 10 GB, always keeping the newest of each and protecting pending work.
- Run `make lint` before any commit.
- For signed DMG preparation/publication, use `.agents/skills/release-meeting-notes/SKILL.md` and the README release workflow (`make release`, then `make publish`).
- Preserve bundle ID `com.jona.meeting-notes`, the Sparkle signing key, and the Apple signing team. Release credentials stay in local configuration/Keychain.
- Release builds enable Sparkle; ad-hoc builds disable it. Updates must not interrupt recording, transcription, or permission setup.

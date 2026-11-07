# Agent instructions

- This is a native Swift macOS menu-bar app. Keep the Makefile; Swift Package Manager builds the bundled transcription helper (whisper.cpp XCFramework for speech recognition and VAD, FluidAudio for diarization). Models download on first use with checksum verification. No OBS, FluidVoice, Codex, Homebrew, Python or Node runtime dependency.
- For live end-to-end checks, use the local Teams test environment in `scripts/devenv` (see `docs/development.md`): a dummy Teams account, virtual audio devices and synthetic speech. `make test` stays device-free.
- Never overwrite a completed recording. Requested transcript corrections update the transcript directly, without retaining an original copy or edit history. Retention removes the oldest recordings above 10 GB, keeping the newest and protecting pending work. Transcripts and their records are never automatically deleted.
- Run `make lint` before any commit.
- For signed DMG preparation/publication, use `.agents/skills/release-meeting-notes/SKILL.md` and the README release workflow (`make release`, then `make publish`).
- Preserve bundle ID `com.jona.meeting-notes`, the Sparkle signing key, and the Apple signing team. Release credentials stay in local configuration/Keychain.
- Release builds enable Sparkle; ad-hoc builds disable it. Updates must not interrupt recording, transcription, or permission setup.

## Git workflow

- Squash-merge feature work locally into `main`, with focused commits describing the final changes.
- Push only `main`; keep working branches local.
- This repository is public. Keep public documentation general; private infrastructure and environment details must stay out of Git history. Review outgoing files and commits for credentials, private data and machine-specific artifacts before committing or publishing.

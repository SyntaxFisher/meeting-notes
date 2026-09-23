# Agent instructions

- This is a native Swift macOS menu-bar app. Keep the Makefile; Swift Package Manager builds the bundled FluidAudio helper. No OBS, FluidVoice, Codex, or Node runtime dependency.
- Do not record microphone or system audio or join a call during automated tests. A live recording test requires separate user approval. Existing files and generated fixtures may be processed locally.
- Never overwrite a completed recording or transcript. Retention removes the oldest saved pairs above 1 GB, protecting pending work.
- Run `make lint` before any commit.

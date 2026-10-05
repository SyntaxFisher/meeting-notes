---
name: release-meeting-notes
description: Prepare, verify, publish, or recover signed and notarized Meeting Notes macOS DMG releases and the Sparkle update feed in this repository.
---

# Release Meeting Notes

Read [AGENTS.md](../../../AGENTS.md), [README Releasing](../../../README.md#releasing), and [scripts/build.py](../../../scripts/build.py). The script is the release implementation; do not create a second one in this skill.

## App-specific constraints

- Repository `SyntaxFisher/meeting-notes`; app `Meeting Notes.app`; executable `MeetingNotes`; bundle ID and Sparkle account `com.jona.meeting-notes`. Preserve identity and Apple signing team.
- Apple silicon and macOS 26+ only. Do not copy Idle Brew's Intel/macOS 13 promise. Swift Package Manager builds the pinned FluidAudio transcription helper; package its resources and license as well as Sparkle's.
- `make build` creates an ad-hoc app with updates disabled. `make install` installs/launches that development build and refuses a running app. Use the DMG to test release installation.
- Run `make lint` before every commit, plus `make test` and `make build` for release changes. Tests must not open microphones, capture system audio, or join calls. Live recording requires separate explicit user approval. Fixture processing is allowed.
- Updates defer checks/restarts while work or permission setup is active. Keep that protection intact. Do not overwrite recordings/transcripts or change retention as part of release work.
- Preparing a release does not authorize publication. When the user asks to release/publish, carry through the verified GitHub workflow. Installing or launching the app is separate from preparing a DMG.

## Signing on Jona's Mac

Verify `gh auth status`, `security find-identity -v -p codesigning`, and `xcrun --find notarytool`. Established identity: `Developer ID Application: Jona Bihl (94DW6CHJD7)`.

Local `~/.config/meeting-notes-release/config.json` (0600) contains `signing.identity` and the `apple.key_path`, `apple.key_id`, `apple.issuer_id` reference reused from Idle Brew/Wallpaper Motion. Never print private-key contents or tokens or put them in Git, assets, or Knowledge Base. See README for environment overrides.

Sparkle's private key is in login Keychain under `com.jona.meeting-notes`; `Info.plist` has its public key. Reuse the existing key. If macOS prompts for `generate_appcast` or `sign_update`, keep the command pending and ask the user to approve the actual Keychain prompt. Do not replace the key to avoid access approval.

Search Knowledge Base for Meeting Notes and Apple Developer account and macOS release setup for history. Current configuration and verification determine readiness.

## Prepare and verify

1. Check the working tree and fetch `origin/main`; preserve unrelated changes. Inspect GitHub releases and feed before selecting a version. Increase both marketing version (three parts) and integer build; write `releases/<version>.md`.
2. Run the required checks, review the diff, commit, and push. `make release` requires a clean tree; `make publish` additionally requires `origin/main` at the exact manifest commit.
3. Run `make release`. It signs nested code before the app, uses Hardened Runtime/timestamps and `Release.entitlements` for microphone access, notarizes/staples both app and DMG, checks Gatekeeper, and verifies both feed and update signatures.
4. Inspect `build/releases/<version>/manifest.json` and both notarization JSON results. Both must be `Accepted`; source commit and asset hashes must match.
5. Mount the DMG read-only. Verify the visible drag instruction/arrow, Applications shortcut, and packaged `Meeting Notes.app`. Run `codesign --verify --deep --strict`, `xcrun stapler validate`, and `spctl --assess --type execute --verbose=2` on the packaged app. Confirm arm64 for both `Contents/MacOS/MeetingNotes` and `MeetingTranscriber`, and confirm the app's audio-input entitlement. Unmount afterward.

Do not change source between preparation and publication: even documentation changes alter the manifest commit. Reconcile source changes and rebuild; never edit the manifest to misrepresent provenance.

## Publish and recover

When authorized, run `make publish`. It tags the exact source, creates/uploads a draft, verifies downloaded hashes, then publishes as Latest. There is no draft-only publish mode. Confirm the public release and compare the public latest appcast with the local verified feed. Required assets: versioned arm64 DMG, `appcast.xml`, `SHA256SUMS`.

Never overwrite a public release or force-move a version tag. Keep older assets for feed history. After interruption inspect the tag, draft/public release, manifest, and source before retrying. A failed preparation preserves its directory: read notarization results/status first and move failed output aside before rebuilding. Avoid duplicate submissions while Apple's outcome is unknown.

A probe can validate the signed public feed and discovery from an isolated older bundle without launching the recording app. This does not test downloading/installing/relaunching an update; report the actual scope. Full update testing needs two released versions and authorized app installation.

After completion, update the existing Meeting Notes Knowledge Base memory with version/build, commit, artifact/release location, verification, and installation status. Link this repository skill as the procedure. Keep secrets out.

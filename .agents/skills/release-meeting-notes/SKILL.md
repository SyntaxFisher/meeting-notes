---
name: release-meeting-notes
description: Prepare, verify, publish, or recover signed and notarized Meeting Notes macOS DMG releases and the Sparkle update feed in this repository.
---

# Release Meeting Notes

Read [AGENTS.md](../../../AGENTS.md), [release guide](../../../docs/releasing.md), and [scripts/build.py](../../../scripts/build.py). The script is the release implementation; do not create a second one in this skill.

## App-specific constraints

- Repository `SyntaxFisher/meeting-notes`; app `Meeting Notes.app`; executable `MeetingNotes`; bundle ID and Sparkle account `com.jona.meeting-notes`. Preserve identity and Apple signing team.
- Apple silicon and macOS 26+ only. Swift Package Manager builds the pinned transcription helper (whisper.cpp XCFramework and FluidAudio); package the whisper framework, FluidAudio resources and all licenses (`NativeTranscription/Licenses/`, FluidAudio, Sparkle).
- `make build` creates an ad-hoc app with updates disabled by default; signed preview builds can enable updates as described in the development guide. `make install` installs/launches that development build and refuses a running app. Use the DMG to test release installation.
- Run `make lint` before every commit, plus `make test` and `make build` for release changes. Automated tests use fixtures; live capture checks use the separate development test environment.
- Updates defer checks/restarts while work or permission setup is active. Keep that protection intact. Do not overwrite recordings/transcripts or change retention as part of release work.
- Preparing a release does not authorize publication. When the user asks to release/publish, carry through the verified GitHub workflow. Installing or launching the app is separate from preparing a DMG.

## Signing setup

Verify `gh auth status`, `security find-identity -v -p codesigning`, and `xcrun --find notarytool`. Use the configured Developer ID Application identity.

Local `~/.config/meeting-notes-release/config.json` (0600) contains the signing identity and notarization credential references. Keep private keys and tokens outside the repository and release assets. See the release guide for environment overrides.

Sparkle's private key is in login Keychain under `com.jona.meeting-notes`; `Info.plist` has its public key. Reuse the existing key.

## Prepare and verify

1. Check the working tree and fetch `origin/main`; preserve unrelated changes. Inspect GitHub releases and feed before selecting a version. Increase both marketing version (three parts) and integer build; write `releases/<version>.md`.
2. Run the required checks, review the diff, commit, and push. `make release` requires a clean tree; `make publish` additionally requires `origin/main` at the exact manifest commit.
3. Run `make release`. It signs nested code before the app, uses Hardened Runtime/timestamps and `Release.entitlements` for microphone access, notarizes/staples both app and DMG, checks Gatekeeper, and verifies both feed and update signatures.
4. Inspect `build/releases/<version>/manifest.json` and both notarization JSON results. Both must be `Accepted`; source commit and asset hashes must match.
5. Mount the DMG read-only. Verify the visible drag instruction/arrow, Applications shortcut, and packaged `Meeting Notes.app`. Run `codesign --verify --deep --strict`, `xcrun stapler validate`, and `spctl --assess --type execute --verbose=2` on the packaged app. Confirm arm64 for both `Contents/MacOS/MeetingNotes` and `MeetingTranscriber`, and confirm the app's audio-input entitlement. Unmount afterward.

Installer artwork must be embedded in `Contents/Resources/InstallerBackground.tiff` before app signing. Keep the approved plain grey layout, heading, drag instruction, arrow, and two icons; no footer or loose background file. `scripts/dmg-layout.py` references the bundled artwork from Finder. Do not use dmgbuild `hide_extensions`: its FinderInfo change invalidates the app signature. Verify the packaged app after layout changes.

Do not change source between preparation and publication: even documentation changes alter the manifest commit. Reconcile source changes and rebuild; never edit the manifest to misrepresent provenance.

## Publish and recover

When authorized, run `make publish`. It tags the exact source, creates/uploads a draft, verifies downloaded hashes, then publishes as Latest. There is no draft-only publish mode. Confirm the public release and compare the public latest appcast with the local verified feed. Required assets: versioned arm64 DMG, `appcast.xml`, `SHA256SUMS`.

Never overwrite a public release or force-move a version tag. Keep older assets for feed history. After interruption inspect the tag, draft/public release, manifest, and source before retrying. A failed preparation preserves its directory: read notarization results/status first and move failed output aside before rebuilding. Avoid duplicate submissions while Apple's outcome is unknown.

A probe can validate the signed public feed and discovery from an isolated older bundle without launching the recording app. This does not test downloading/installing/relaunching an update; report the actual scope. Full update testing needs two released versions and authorized app installation.

After completion, report the published version, release URL, verification results and installation status.

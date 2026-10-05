DEST ?= /Applications
SOURCES = main.swift AppDelegate.swift State.swift Permissions.swift TeamsMuteReader.swift TeamsMonitor.swift TeamsAutoRecord.swift AppLog.swift NativeTranscriber.swift NativeRecorder.swift AudioCapture.swift AudioCaptureHealth.swift RecordingRetention.swift AppUpdater.swift UpdateInstallationGate.swift
SWIFT_FLAGS ?=

.DEFAULT_GOAL := build
.PHONY: build install lint test native release publish dependencies

native:
	xcrun swift build --package-path NativeTranscription -c release --arch arm64 --product MeetingTranscriber --force-resolved-versions

build install release publish dependencies:
	MODE=$@ DEST="$(DEST)" SWIFT_FLAGS="$(SWIFT_FLAGS)" python3 scripts/build.py

lint:
	xcrun swift-format lint --strict $(SOURCES) GenerateIcon.swift scripts/dmg-background.swift Tests/Smoke.swift Tests/CaptureSmoke.swift NativeTranscription/Package.swift NativeTranscription/Sources/MeetingTranscriber/*.swift

test:
	mkdir -p build
	xcrun swiftc $(SWIFT_FLAGS) -O -parse-as-library -target arm64-apple-macos26.0 -o build/MeetingNotesSmoke Tests/Smoke.swift Tests/CaptureSmoke.swift UpdateInstallationGate.swift State.swift Permissions.swift TeamsMuteReader.swift TeamsAutoRecord.swift AppLog.swift NativeRecorder.swift AudioCapture.swift AudioCaptureHealth.swift RecordingRetention.swift NativeTranscriber.swift NativeTranscription/Sources/MeetingTranscriber/TranscriptionAudio.swift
	build/MeetingNotesSmoke

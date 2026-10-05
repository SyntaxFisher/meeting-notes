APP_NAME = Meeting Notes
EXECUTABLE = MeetingNotes
BUNDLE_ID = com.jona.meeting-notes
DEST ?= /Applications
SOURCES = main.swift AppDelegate.swift State.swift Permissions.swift TeamsMuteReader.swift TeamsMonitor.swift TeamsAutoRecord.swift AppLog.swift NativeTranscriber.swift NativeRecorder.swift AudioCapture.swift AudioCaptureHealth.swift RecordingRetention.swift
BUNDLE = build/MeetingNotes.app
SWIFT_FLAGS ?=

.PHONY: build install lint test native

native:
	swift build --package-path NativeTranscription -c release --product MeetingTranscriber --force-resolved-versions

build: native $(BUNDLE)/Contents/MacOS/$(EXECUTABLE)
	cp NativeTranscription/.build/release/MeetingTranscriber "$(BUNDLE)/Contents/MacOS/MeetingTranscriber"
	cp -R NativeTranscription/.build/release/FluidAudio_FluidAudio.bundle "$(BUNDLE)/Contents/Resources/"
	codesign --force --sign - "$(BUNDLE)/Contents/MacOS/MeetingTranscriber"
	codesign --force --sign - --identifier $(BUNDLE_ID) "$(BUNDLE)"

$(BUNDLE)/Contents/MacOS/$(EXECUTABLE): $(SOURCES) Info.plist GenerateIcon.swift
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	swiftc $(SWIFT_FLAGS) -O -target arm64-apple-macos26.0 -o "$@" $(SOURCES)
	swiftc $(SWIFT_FLAGS) -O -target arm64-apple-macos26.0 -o build/GenerateIcon GenerateIcon.swift
	build/GenerateIcon build/AppIcon.iconset
	iconutil -c icns -o build/AppIcon.icns build/AppIcon.iconset
	cp build/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign - --identifier $(BUNDLE_ID) "$(BUNDLE)"

lint:
	swift-format lint --strict $(SOURCES) GenerateIcon.swift Tests/Smoke.swift Tests/CaptureSmoke.swift NativeTranscription/Package.swift NativeTranscription/Sources/MeetingTranscriber/*.swift

test:
	mkdir -p build
	swiftc $(SWIFT_FLAGS) -O -parse-as-library -target arm64-apple-macos26.0 -o build/MeetingNotesSmoke Tests/Smoke.swift Tests/CaptureSmoke.swift State.swift Permissions.swift TeamsMuteReader.swift TeamsAutoRecord.swift AppLog.swift NativeRecorder.swift AudioCapture.swift AudioCaptureHealth.swift RecordingRetention.swift NativeTranscriber.swift NativeTranscription/Sources/MeetingTranscriber/TranscriptionAudio.swift
	build/MeetingNotesSmoke

install: build
	ditto "$(BUNDLE)" "$(DEST)/$(APP_NAME).app"
	open "$(DEST)/$(APP_NAME).app"

APP_NAME = Meeting Notes
EXECUTABLE = MeetingNotes
BUNDLE_ID = com.jona.meeting-notes
DEST ?= /Applications
SOURCES = main.swift AppDelegate.swift AppServices.swift OBSClient.swift AudioChunker.swift State.swift TeamsMuteReader.swift TeamsMuteMirror.swift AppLog.swift
BUNDLE = build/MeetingNotes.app
SWIFT_FLAGS ?=

.PHONY: build install lint test live-check

build: $(BUNDLE)/Contents/MacOS/$(EXECUTABLE)

$(BUNDLE)/Contents/MacOS/$(EXECUTABLE): $(SOURCES) Info.plist GenerateIcon.swift
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	swiftc $(SWIFT_FLAGS) -O -target arm64-apple-macos15.0 -o "$@" $(SOURCES)
	swiftc $(SWIFT_FLAGS) -O -target arm64-apple-macos15.0 -o build/GenerateIcon GenerateIcon.swift
	build/GenerateIcon build/AppIcon.iconset
	iconutil -c icns -o build/AppIcon.icns build/AppIcon.iconset
	cp build/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign - --identifier $(BUNDLE_ID) "$(BUNDLE)"

lint:
	swift-format lint --strict $(SOURCES) GenerateIcon.swift Tests/Smoke.swift

test:
	mkdir -p build
	swiftc $(SWIFT_FLAGS) -O -parse-as-library -target arm64-apple-macos15.0 -o build/MeetingNotesSmoke Tests/Smoke.swift AppServices.swift OBSClient.swift AudioChunker.swift State.swift TeamsMuteReader.swift AppLog.swift
	build/MeetingNotesSmoke

live-check: test
	build/MeetingNotesSmoke --live

install: build
	ditto "$(BUNDLE)" "$(DEST)/$(APP_NAME).app"
	open "$(DEST)/$(APP_NAME).app"

DEST ?= /Applications
SOURCES = $(filter-out GenerateIcon.swift,$(wildcard *.swift))
# The smoke tests link everything except the app's entry point and the parts that need Sparkle
# or a running app delegate.
TEST_SOURCES = $(filter-out main.swift AppDelegate.swift AppUpdater.swift AppIntents.swift,$(SOURCES))
HELPER_SHARED = NativeTranscription/Sources/MeetingTranscriber/SpeechPlan.swift NativeTranscription/Sources/MeetingTranscriber/TranscriptSegments.swift NativeTranscription/Sources/MeetingTranscriber/EchoFilter.swift
SWIFT_FLAGS ?=

.DEFAULT_GOAL := build
.PHONY: build install lint test native release publish dependencies devenv

native:
	xcrun swift build --package-path NativeTranscription -c release --arch arm64 --product MeetingTranscriber --force-resolved-versions

build install release publish dependencies:
	MODE=$@ DEST="$(DEST)" SWIFT_FLAGS="$(SWIFT_FLAGS)" python3 scripts/build.py

lint:
	xcrun swift-format lint --strict $(SOURCES) GenerateIcon.swift scripts/dmg-background.swift Tests/*.swift NativeTranscription/Package.swift NativeTranscription/Sources/MeetingTranscriber/*.swift scripts/devenv/TeamsControl.swift

test:
	mkdir -p build
	xcrun swiftc $(SWIFT_FLAGS) -O -parse-as-library -target arm64-apple-macos26.0 -o build/MeetingNotesSmoke Tests/*.swift $(TEST_SOURCES) $(HELPER_SHARED)
	build/MeetingNotesSmoke

devenv:
	python3 scripts/devenv/devenv.py setup

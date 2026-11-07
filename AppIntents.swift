import AppIntents
import Foundation

/// Shortcuts actions. They run inside the app and go through its command layer, so a refused
/// command fails the shortcut with the same reason every other surface reports.
@MainActor
private func performIntentCommand(_ command: MeetingCommand) async throws -> CommandOutcome {
  guard let app = MeetingAppDelegate.current else {
    throw MeetingError("Meeting Notes is not running.")
  }
  return try await app.commands.perform(command, source: .shortcuts).get()
}

struct StartRecordingIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Recording"
  static let description = IntentDescription(
    "Starts recording the microphone and the call audio: by default Microsoft Teams during a Teams meeting, otherwise everything the Mac plays."
  )

  @MainActor
  func perform() async throws -> some IntentResult {
    _ = try await performIntentCommand(.start(title: nil))
    return .result()
  }
}

struct StopRecordingIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop Recording and Transcribe"
  static let description = IntentDescription(
    "Stops the current recording and queues it for transcription on this Mac.")

  @MainActor
  func perform() async throws -> some IntentResult {
    _ = try await performIntentCommand(.stop)
    return .result()
  }
}

struct GetLatestTranscriptIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Latest Transcript"
  static let description = IntentDescription(
    "Returns the text of the most recent transcript.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let app = MeetingAppDelegate.current else {
      throw MeetingError("Meeting Notes is not running.")
    }
    if let reason = app.libraryStore.unavailableReason { throw MeetingError(reason) }
    let library = app.engine.library
    guard let latest = await app.libraryStore.current().latestComplete,
      let transcript = library.transcriptURL(of: latest)
    else { throw MeetingError("No transcript yet.") }
    return .result(value: try String(contentsOf: transcript, encoding: .utf8))
  }
}

struct MeetingNotesShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartRecordingIntent(),
      phrases: ["Start recording in \(.applicationName)"],
      shortTitle: "Start Recording", systemImageName: "record.circle")
    AppShortcut(
      intent: StopRecordingIntent(),
      phrases: ["Stop recording in \(.applicationName)"],
      shortTitle: "Stop Recording", systemImageName: "stop.circle")
    AppShortcut(
      intent: GetLatestTranscriptIntent(),
      phrases: ["Get the latest transcript from \(.applicationName)"],
      shortTitle: "Latest Transcript", systemImageName: "doc.text")
  }
}

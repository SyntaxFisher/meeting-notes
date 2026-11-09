import Foundation

/// `MeetingNotes transcribe <audio> <output.txt> [--capture <directory>] [--name <local name>]
/// [--title <title>]` transcribes an existing recording like the app does after a meeting and
/// writes the transcript and a meeting record next to it (`<output>.json`). A capture directory
/// holds the separate `microphone.aac` and `system.aac` tracks with `capture.json`, and
/// optionally `participants.json` and `speaking.json`. Existing files are never overwritten.
enum TranscribeCommand {
  static let usage =
    "usage: MeetingNotes transcribe <audio> <output.txt> [--capture <directory>] [--name <local name>] [--title <title>]"

  struct Options: Equatable {
    var audio: URL
    var output: URL
    var capture: URL?
    var name: String?
    var title: String?
  }

  static func parse(_ arguments: [String]) -> Options? {
    var positional: [String] = []
    var named: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if ["--capture", "--name", "--title"].contains(argument) {
        guard index + 1 < arguments.count else { return nil }
        named[argument] = arguments[index + 1]
        index += 2
      } else if argument.hasPrefix("--") {
        return nil
      } else {
        positional.append(argument)
        index += 1
      }
    }
    guard positional.count == 2 else { return nil }
    return Options(
      audio: URL(fileURLWithPath: positional[0]), output: URL(fileURLWithPath: positional[1]),
      capture: named["--capture"].map { URL(fileURLWithPath: $0, isDirectory: true) },
      name: named["--name"], title: named["--title"])
  }

  @MainActor
  static func run(_ options: Options) async -> Int32 {
    let recordFile = options.output.deletingPathExtension().appendingPathExtension("json")
    for file in [options.output, recordFile]
    where FileManager.default.fileExists(atPath: file.path) {
      FileHandle.standardError.write(Data("\(file.path) already exists.\n".utf8))
      return 1
    }
    do {
      let result = try await NativeTranscriber().transcribe(
        file: options.audio, capture: options.capture)
      let roster = options.capture.flatMap {
        try? JSONDecoder().decode(
          ParticipantRoster.self,
          from: Data(contentsOf: $0.appendingPathComponent("participants.json")))
      }
      let startedAt =
        MeetingFiles.date(fromID: options.audio.deletingPathExtension().lastPathComponent)
        ?? (try? options.audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
      var record = MeetingRecord(
        id: options.output.deletingPathExtension().lastPathComponent,
        title: options.title, startedAt: startedAt,
        status: .complete)
      record.audioFile = options.audio.lastPathComponent
      record.source = options.capture.flatMap {
        try? JSONDecoder().decode(
          CaptureManifest.self, from: Data(contentsOf: $0.appendingPathComponent("capture.json")))
      }.map { MeetingSource($0.systemAudio) }
      record.transcriptFile = options.output.lastPathComponent
      let configured = (try? AppConfig.read(from: AutomationPaths.standard.configFile))?
        .localSpeakerName
      let text = TranscriptDocument.compose(
        result, into: &record,
        localName: TranscriptDocument.localSpeakerName(
          configured: options.name ?? configured, teamsName: roster?.localParticipant?.name),
        roster: roster, speaking: options.capture.flatMap(SpeakingTimeline.load(fromCapture:)))
      try MeetingFiles.publish(
        JSONCoding.encoder(pretty: true).encode(record), to: recordFile)
      try MeetingFiles.publish(Data(text.utf8), to: options.output)
      print("\(result.mode.rawValue): \(options.output.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      return 1
    }
  }
}

import Foundation

/// `MeetingNotes replay <archive> <output>` runs the current app over one reconstruction
/// archive (see `ReconstructionArchive`) and writes what it decided then and now into the new
/// directory `<output>`, which must not exist:
///
/// - `teams.json`: the Teams trace replayed through the current detection, next to the recorded
///   mute states, automatic recording decisions and speakers (`TeamsReplay`).
/// - `before.txt`, `before.json`: the archived helper result with the archived speaker names.
/// - `after.txt`, `after.json`, `after-record.json`: the copied capture tracks transcribed by
///   the current helper and named with the current logic, using the replayed speaker timeline
///   when the archive has a trace.
/// - `summary.json`: the differences.
///
/// The archive itself is only read, and no meeting in the library changes.
enum ReplayCommand {
  static let usage = "usage: MeetingNotes replay <archive directory> <new output directory>"

  @MainActor
  static func run(_ arguments: [String]) async -> Int32 {
    guard arguments.count == 2 else {
      FileHandle.standardError.write(Data((usage + "\n").utf8))
      return 2
    }
    let archive = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let manager = FileManager.default
    guard !manager.fileExists(atPath: output.path) else {
      FileHandle.standardError.write(Data("\(output.path) already exists.\n".utf8))
      return 1
    }
    do {
      try manager.createDirectory(at: output, withIntermediateDirectories: true)
      var summary: [String: Any] = [
        "archive": archive.path, "app": ReconstructionArchive.appVersion,
      ]
      var replayedSpeaking: SpeakingTimeline?
      let trace = archive.appendingPathComponent("teams-trace.jsonl")
      if let data = try? Data(contentsOf: trace) {
        let teams = TeamsReplay.replay(data)
        try write(teams, to: output.appendingPathComponent("teams.json"))
        summary["teams"] = teams.differences
        replayedSpeaking = teams.replayedSpeaking
        print(
          "teams: "
            + (teams.differences.isEmpty
              ? "same decisions" : teams.differences.joined(separator: "; ")))
      }
      let details = try? JSONDecoder().decode(
        ReconstructionArchive.Transcription.self,
        from: Data(contentsOf: archive.appendingPathComponent("transcription.json")))
      let source = archive.appendingPathComponent("capture", isDirectory: true)
      guard manager.fileExists(atPath: source.path) else {
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("summary.json"))
        print("No capture tracks in the archive; only the Teams trace was replayed.")
        return 0
      }
      let capture = output.appendingPathComponent("capture", isDirectory: true)
      try copyCapture(source, to: capture, speaking: replayedSpeaking)
      let roster = try? JSONDecoder().decode(
        ParticipantRoster.self,
        from: Data(contentsOf: capture.appendingPathComponent("participants.json")))
      let localName = roster?.localParticipant?.name ?? TranscriptDocument.fallbackLocalName
      if let before = details?.helper {
        try write(details, to: output.appendingPathComponent("before.json"))
        try Data(lines(before, names: details?.naming?.map(\.name), localName: localName).utf8)
          .write(to: output.appendingPathComponent("before.txt"))
      }
      let audio = output.appendingPathComponent("audio.m4a")
      try NativeRecorder.mix(directory: capture, destination: audio)
      let result = try await NativeTranscriber().transcribe(file: audio, capture: capture)
      let speaking = SpeakingTimeline.load(fromCapture: capture)
      var record = MeetingRecord(
        id: archive.lastPathComponent, startedAt: Date(), status: .complete)
      let text = TranscriptDocument.compose(
        result, into: &record, localName: localName, roster: roster, speaking: speaking)
      let naming = TranscriptDocument.naming(
        result, localName: localName, roster: roster, speaking: speaking)
      var after = result
      after.voiceEmbeddings = nil
      try write(
        ReconstructionArchive.Transcription(
          app: ReconstructionArchive.appVersion, helper: after, naming: naming),
        to: output.appendingPathComponent("after.json"))
      try Data(text.utf8).write(to: output.appendingPathComponent("after.txt"))
      try write(record, to: output.appendingPathComponent("after-record.json"))
      summary["transcription"] = compare(details?.helper, details?.naming, result, naming)
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("summary.json"))
      print("Replayed into \(output.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  /// Copies the archived capture tracks; with a replayed speaker timeline it replaces the
  /// archived one, also when the replay found nobody speaking.
  static func copyCapture(_ source: URL, to capture: URL, speaking: SpeakingTimeline?) throws {
    try FileManager.default.copyItem(at: source, to: capture)
    if let speaking {
      try JSONEncoder().encode(speaking).write(
        to: capture.appendingPathComponent("speaking.json"))
    }
  }

  private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
  }

  /// One `[seconds] label: text` line per segment, with the archived names.
  private static func lines(_ result: TranscriptSegments, names: [String?]?, localName: String)
    -> String
  {
    result.segments.enumerated().map { index, segment in
      let name =
        segment.source == .microphone
        ? localName : (names?[index] ?? "\(segment.source.rawValue) \(segment.speaker)")
      return String(format: "[%.2f] %@: %@", segment.start, name, segment.text)
    }.joined(separator: "\n") + "\n"
  }

  private static func compare(
    _ before: TranscriptSegments?, _ beforeNames: [SpeakerFusion.Decision]?,
    _ after: TranscriptSegments, _ afterNames: [SpeakerFusion.Decision]?
  ) -> [String: Any] {
    func counts(_ result: TranscriptSegments?, _ names: [SpeakerFusion.Decision]?) -> [String: Any]
    {
      let segments = result?.segments ?? []
      return [
        "segments": segments.count,
        "microphoneWords": segments.filter { $0.source == .microphone }
          .reduce(0) { $0 + $1.text.split(separator: " ").count },
        "namedRemoteSegments": names?.filter { $0.name != nil }.count ?? 0,
        "copiedWords": result?.echo?.copiedWords ?? 0,
      ]
    }
    var summary: [String: Any] = [
      "before": counts(before, beforeNames), "after": counts(after, afterNames),
      "rejections": zip(after.segments, afterNames ?? []).compactMap { segment, decision in
        decision.rejection.map { rejection in
          let closest = decision.candidate.map { name in
            String(
              format: " [closest %@ %.2f, next %.2f]", name, decision.candidateSimilarity ?? 0,
              decision.runnerUpSimilarity ?? 0)
          }
          return String(format: "%.2f %@: ", segment.start, decision.name ?? "anonymous")
            + rejection + (closest ?? "")
        }
      },
    ]
    if let before, before.segments == after.segments {
      let changed = zip(beforeNames ?? [], afterNames ?? []).enumerated().filter {
        $0.element.0.name != $0.element.1.name
      }.map { index, pair in
        "\(String(format: "%.2f", after.segments[index].start)): \(pair.0.name ?? "-") -> \(pair.1.name ?? "-") (\(pair.1.reason.rawValue))"
      }
      summary["sameSegments"] = true
      summary["changedNames"] = changed
    } else {
      summary["sameSegments"] = false
    }
    return summary
  }
}

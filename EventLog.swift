import Foundation

/// Meeting lifecycle events, each appended to `events.jsonl` with the meeting's metadata.
enum LifecycleEvent: String, CaseIterable, Sendable {
  case recordingStarted = "recording.started"
  case recordingStopped = "recording.stopped"
  case recordingDiscarded = "recording.discarded"
  case recordingFailed = "recording.failed"
  case recordingInterrupted = "recording.interrupted"
  case transcriptionQueued = "transcription.queued"
  case transcriptionStarted = "transcription.started"
  case transcriptReady = "transcript.ready"
  case transcriptionFailed = "transcription.failed"
  case meetingDiscarded = "meeting.discarded"
  case meetingDeleted = "meeting.deleted"
}

/// What the event log records about a meeting: its record's metadata with absolute
/// paths, without the transcript segments.
struct MeetingInfo: Equatable {
  var id: String
  var title: String?
  var status: MeetingStatus
  var startedAt: Date?
  var endedAt: Date?
  var durationSeconds: Double?
  var audioPath: String?
  var transcriptPath: String?
  var recordPath: String?
  var speakers: [String] = []
  var localSpeaker: String?
  var participants: [String] = []
  var automatic: Bool?
  var error: String?

  init(record: MeetingRecord, library: MeetingLibrary) {
    id = record.id
    title = record.title
    status = record.status
    startedAt = record.startedAt
    endedAt = record.endedAt
    durationSeconds = record.durationSeconds
    audioPath = library.audioURL(of: record)?.path
    transcriptPath = library.transcriptURL(of: record)?.path
    let recordFile = library.recordURL(for: record.id)
    recordPath = FileManager.default.fileExists(atPath: recordFile.path) ? recordFile.path : nil
    speakers = record.speakers.map(\.displayName)
    localSpeaker = record.speakers.first(where: \.isLocalUser)?.displayName
    participants = record.participants?.participants.map(\.name) ?? []
    automatic = record.trigger.map { $0 == .automatic }
    error = record.error
  }

  var dictionary: [String: Any] {
    func value(_ optional: Any?) -> Any { optional ?? NSNull() }
    return [
      "id": id,
      "title": value(title),
      "status": status.rawValue,
      "startedAt": value(startedAt.map(AutomationFormat.timestamp)),
      "endedAt": value(endedAt.map(AutomationFormat.timestamp)),
      "durationSeconds": value(durationSeconds.map(AutomationFormat.seconds)),
      "audioPath": value(audioPath),
      "transcriptPath": value(transcriptPath),
      "recordPath": value(recordPath),
      "speakers": speakers,
      "localSpeaker": value(localSpeaker),
      "participants": participants,
      "automatic": value(automatic),
      "error": value(error),
    ]
  }
}

/// Append-only lifecycle log for agents: one JSON object per line in `events.jsonl`. When the
/// file reaches its size limit it moves to `events.previous.jsonl`, replacing the older one.
final class EventLog: @unchecked Sendable {
  static let shared = EventLog(file: AutomationPaths.standard.eventsFile)

  let file: URL
  private let maxBytes: Int
  private let lock = NSLock()

  init(file: URL, maxBytes: Int = 1_000_000) {
    self.file = file
    self.maxBytes = maxBytes
  }

  var previousFile: URL {
    file.deletingLastPathComponent().appendingPathComponent("events.previous.jsonl")
  }

  static func line(
    time: Date, event: String, meeting: String?, details: [String: Any]
  ) throws -> Data {
    var entry: [String: Any] = [
      "time": AutomationFormat.timestamp(time), "event": event, "details": details,
    ]
    entry["meeting"] = meeting ?? NSNull()
    var data = try JSONSerialization.data(
      withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
  }

  func record(
    _ event: String, meeting: String? = nil, details: [String: Any] = [:], at time: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }
    do {
      let data = try Self.line(time: time, event: event, meeting: meeting, details: details)
      let manager = FileManager.default
      try manager.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
      if let size, size + data.count > maxBytes, size > 0 {
        if manager.fileExists(atPath: previousFile.path) {
          try manager.removeItem(at: previousFile)
        }
        try manager.moveItem(at: file, to: previousFile)
      }
      if !manager.fileExists(atPath: file.path) {
        guard
          manager.createFile(
            atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MeetingError("Cannot create \(file.path).") }
      }
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      AppLog.event("events.writeFailed", error.localizedDescription)
    }
  }
}

enum AutomationFormat {
  /// Seconds rounded to tenths as a decimal, so JSON shows `64.3` instead of `64.299999999999997`.
  static func seconds(_ value: TimeInterval) -> NSDecimalNumber {
    NSDecimalNumber(
      string: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value))
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    return formatter.string(from: date)
  }
}

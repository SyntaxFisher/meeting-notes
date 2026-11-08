import CryptoKit
import Foundation

/// Opaque continuation state binds pages to the same query and transcript revision.
struct MeetingCursor: Codable {
  var kind: String
  var meeting: String? = nil
  var revision: Int? = nil
  var offset = 0
  var character = 0
  var queries: [String]? = nil
  var since: String? = nil
  var until: String? = nil
  var status: String? = nil
  var limit = 10
  var signature: String? = nil

  enum CodingKeys: String, CodingKey {
    case kind = "k"
    case meeting = "m"
    case revision = "r"
    case offset = "o"
    case character = "c"
    case queries = "q"
    case since = "s"
    case until = "u"
    case status = "t"
    case limit = "l"
    case signature = "v"
  }

  var token: String { (try! JSONEncoder().encode(self)).base64EncodedString() }

  static func read(_ value: String, kind: String) throws -> Self {
    guard value.count <= 8192, let data = Data(base64Encoded: value),
      let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.kind == kind,
      cursor.offset >= 0, cursor.character >= 0, (1...50).contains(cursor.limit)
    else { throw MeetingError("Invalid cursor. Start this read again.") }
    return cursor
  }

  static func signature(_ records: [MeetingRecord]) -> String {
    let text = records.map { "\($0.id):\($0.revision):\($0.status.rawValue)" }.joined(
      separator: "\n")
    return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}

/// Compact agent output, independent of storage and UI representations.
enum MeetingAgentView {
  static let textBudget = 12000

  static func integer(
    _ args: [String: JSONValue], _ key: String, default fallback: Int, range: ClosedRange<Int>
  ) throws -> Int {
    guard let value = args[key] else { return fallback }
    guard case .number = value, let number = value.intValue, range.contains(number) else {
      throw MeetingError(
        "\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).")
    }
    return number
  }

  static func revision(_ args: [String: JSONValue]) throws -> Int {
    guard args["revision"] != nil else {
      throw MeetingError("Read the meeting first and pass its revision.")
    }
    return try integer(args, "revision", default: 0, range: 0...Int.max / 2)
  }

  static func exactID(_ args: [String: JSONValue], library: MeetingLibrary) throws -> String {
    guard let id = args["meeting_id"]?.stringValue, try library.resolve(id) == id else {
      throw MeetingError("Read the meeting first and pass its exact meeting_id.")
    }
    return id
  }

  static func summary(_ record: MeetingRecord) -> String {
    var text = "\(record.id) | \(record.displayTitle) | \(JSONCoding.formatDate(record.startedAt))"
    if let duration = record.durationSeconds { text += " | \(MeetingLibrary.timestamp(duration))" }
    text += " | \(record.status.rawValue)\nurl: \(record.link.string)"
    return text
  }

  static func page(
    _ record: MeetingRecord, library: MeetingLibrary, arguments: [String: JSONValue],
    cursor: MeetingCursor? = nil, suggestsTitles: Bool = false, suggestsCorrections: Bool = false,
    suggestsSummaries: Bool = false
  ) throws -> MCPServer.ToolResult {
    if let cursor, cursor.meeting != record.id || cursor.revision != record.revision {
      throw MeetingError("This meeting changed. Read it again before continuing or editing.")
    }
    var index = cursor?.offset ?? 0
    var character = cursor?.character ?? 0
    let context = try integer(arguments, "context", default: 2, range: 0...10)
    var stop = record.segments.count
    if let passage = arguments["passage"]?.stringValue {
      let target = try record.segmentIndex(for: passage)
      index = max(0, target - context)
      stop = min(record.segments.count, target + context + 1)
    } else if let at = arguments["at"]?.stringValue {
      let seconds = try time(at)
      guard !MeetingLink.isPastEnd(seconds, of: record),
        let target = MeetingLink.segmentIndex(at: seconds, in: record.segments)
      else { throw MeetingError("That time is outside this transcript.") }
      index = max(0, target - context)
      stop = min(record.segments.count, target + context + 1)
    }
    guard index <= record.segments.count,
      index < record.segments.count || character == 0
    else {
      throw MeetingError("Invalid cursor. Read the meeting again.")
    }
    var lines = [
      "# \(record.displayTitle)", "meeting_id: \(record.id)", "revision: \(record.revision)",
      "url: \(record.link.string)",
    ]
    if cursor == nil {
      lines.append(
        "\(JSONCoding.formatDate(record.startedAt)) | \(record.status.rawValue)"
          + (record.durationSeconds.map { " | \(MeetingLibrary.timestamp($0))" } ?? ""))
      if let path = library.audioURL(of: record)?.path { lines.append("recording_path: \(path)") }
      if !record.speakers.isEmpty {
        lines.append(
          "Speakers: "
            + record.speakers.map {
              "\($0.label)=\($0.displayName)\($0.isLocalUser ? " (you)" : $0.name == nil && $0.identity == .unidentified ? " (unidentified)" : "")"
            }.joined(separator: "; "))
      }
      if let participants = record.participants?.participants, !participants.isEmpty {
        lines.append("Participants: " + participants.map(\.name).joined(separator: "; "))
      }
      if let summary = record.summary { lines.append("Summary: \(summary)") }
      if suggestsTitles, record.status == .complete, record.needsAgentTitle {
        lines.append("suggest_topic: true")
      }
      if suggestsSummaries, record.status == .complete, record.summary == nil,
        !record.segments.isEmpty
      {
        lines.append("suggest_summary: true")
      }
      if suggestsCorrections, record.status == .complete, !record.segments.isEmpty {
        lines.append("suggest_corrections: true")
      }
    }
    if record.status != .complete {
      if let error = record.error { lines.append("Error: \(error)") }
      if record.status.needsAttention {
        lines.append(
          library.work(for: record).canRetry
            ? "Use retry_meeting if asked to retry."
            : "No usable recording remains for retry.")
      } else {
        lines.append("Transcript not ready. Read this meeting again later.")
      }
      return .init(text: lines.joined(separator: "\n"))
    }
    let first = index
    var remaining = textBudget
    var passages: [String] = []
    while index < stop, remaining > 0, passages.count < 100 {
      let segment = record.segments[index]
      guard character <= segment.text.count else {
        throw MeetingError("Invalid passage cursor. Read the meeting again.")
      }
      let rest = segment.text.dropFirst(character)
      // Keep passages whole when they fit on a fresh page.
      if !passages.isEmpty, rest.count > remaining { break }
      let text = String(rest.prefix(remaining))
      let partial = text.count < rest.count
      let marker: String
      if character > 0 || partial {
        marker =
          " [characters \(character + 1)–\(character + text.count)/\(segment.text.count); \(partial ? "partial; continue before editing" : "final part")]"
      } else {
        marker = ""
      }
      passages.append(
        "\(record.segmentID(at: index)) \(MeetingLibrary.timestamp(segment.start)) \(segment.speaker)\(marker): \(text)"
      )
      remaining -= max(1, text.count)
      if partial {
        character += text.count
        break
      }
      index += 1
      character = 0
    }
    lines.append(
      "Passages \(record.segments.isEmpty ? 0 : first + 1)–\(character > 0 ? index + 1 : index) of \(record.segments.count)."
    )
    lines.append(contentsOf: passages)
    if index < record.segments.count {
      let next = MeetingCursor(
        kind: "get_meeting", meeting: record.id, revision: record.revision,
        offset: index, character: character)
      lines.append("next_cursor: \(next.token)")
    } else {
      lines.append("End of transcript.")
    }
    return .init(text: lines.joined(separator: "\n"))
  }

  static func time(_ text: String) throws -> Double {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else {
      throw MeetingError("at must be seconds or HH:MM:SS.")
    }
    var result = 0.0
    for (index, part) in parts.enumerated() {
      guard let value = Double(part), value.isFinite, value >= 0,
        index == 0 || value < 60
      else { throw MeetingError("at must be seconds or HH:MM:SS.") }
      result = result * 60 + value
    }
    guard result.isFinite else { throw MeetingError("Invalid time.") }
    return result
  }

  static func status(_ status: StatusSnapshot) -> MCPServer.ToolResult {
    var lines: [String] = []
    if let recording = status.recording {
      lines.append(
        "Recording: \(recording.meetingId) | \(recording.title ?? "Untitled meeting") | \(MeetingLibrary.timestamp(recording.elapsedSeconds))"
      )
      lines.append("url: \(MeetingLink(meetingID: recording.meetingId).string)")
      if recording.mutedInTeams == true { lines.append("Your microphone is muted in Teams.") }
    } else if status.startingRecording {
      lines.append("Recording is starting.")
    } else if status.canStartRecording {
      lines.append("Ready to record.")
    } else if !status.running {
      lines.append("App closed; recording controls open it automatically.")
    } else {
      lines.append(
        "Recording unavailable: \(status.startBlockedReason ?? "Open Meeting Notes to resolve setup.")"
      )
    }
    for work in status.queue.prefix(10) {
      lines.append(
        "Processing: \(work.meetingId) | \(work.title ?? "Untitled meeting") | \(work.status.rawValue)\nurl: \(MeetingLink(meetingID: work.meetingId).string)"
      )
    }
    for work in status.attention.prefix(10) {
      lines.append(
        "Needs attention: \(work.meetingId) | \(work.title ?? "Untitled meeting") | \(work.error ?? work.status.rawValue) | \(work.canRetry == true ? "can retry" : "cannot retry")\nurl: \(MeetingLink(meetingID: work.meetingId).string)"
      )
    }
    if status.queue.count > 10 || status.attention.count > 10 {
      lines.append("More meetings: use list_meetings with a status filter.")
    }
    return .init(text: lines.joined(separator: "\n"))
  }

  static func mutation(_ result: MeetingEditResult) -> JSONValue {
    [
      "meeting_id": .string(result.record.id), "revision": .number(Double(result.record.revision)),
      "changed": .bool(result.changed), "url": .string(result.record.link.string),
    ]
  }
}

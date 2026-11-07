import Foundation

struct MeetingTextChange: Sendable {
  var segmentID: String
  var text: String
}

struct MeetingEditResult: Sendable {
  var record: MeetingRecord
  var changed: Bool
}

enum MeetingEditConflict: LocalizedError {
  case revision(expected: Int, current: Int)

  var userFacingDescription: String {
    switch self {
    case .revision:
      "This meeting changed while you were editing. Review the latest version; your draft is kept."
    }
  }

  var errorDescription: String? {
    switch self {
    case .revision(let expected, let current):
      "Revision conflict: expected \(expected), current revision is \(current). Read the current meeting before changing it."
    }
  }
}

extension MeetingRecord {
  func segmentID(at index: Int) -> String { "s\(index + 1)" }

  func segmentIndex(for id: String) throws -> Int {
    guard id.first == "s", let ordinal = Int(id.dropFirst()), ordinal > 0,
      ordinal <= segments.count, id == "s\(ordinal)"
    else { throw MeetingError("Unknown segment \"\(id)\". Read the meeting's current segments.") }
    return ordinal - 1
  }

  fileprivate mutating func edit(_ body: (inout MeetingRecord) throws -> Void) throws -> Bool {
    var next = self
    try body(&next)
    guard
      next.segments != segments || next.speakers != speakers || next.title != title
        || next.titleSource != titleSource || next.summary != summary
    else { return false }
    guard revision < Int.max else { throw MeetingError("The meeting revision limit was reached.") }
    next.revision = revision + 1
    self = next
    return true
  }

  fileprivate func speakerLabel(for reference: String) throws -> String {
    let labelMatches = speakers.filter { MeetingLibrary.label($0.label, matches: reference) }
    if labelMatches.count == 1 { return labelMatches[0].label }
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let names = speakers.filter {
      $0.name.map { MeetingLibrary.normalized($0) == MeetingLibrary.normalized(reference) } ?? false
    }
    if names.count == 1 { return names[0].label }
    if names.count > 1 {
      throw MeetingError(
        "\"\(reference)\" names several speakers. Use their labels: \(names.map(\.label).joined(separator: ", "))."
      )
    }
    throw MeetingError(
      "\"\(reference)\" is not a speaker in this meeting. Speakers: \(speakers.map(\.label).joined(separator: ", "))."
    )
  }

  fileprivate mutating func orderSpeakers() {
    let order = segments.map(\.speaker)
    speakers.sort {
      let left = order.firstIndex(of: $0.label) ?? Int.max
      let right = order.firstIndex(of: $1.label) ?? Int.max
      return left == right ? $0.label < $1.label : left < right
    }
  }
}

extension MeetingLibrary {
  @discardableResult
  func editTranscript(
    _ id: String, changes: [MeetingTextChange], expectedRevision: Int
  ) throws -> MeetingEditResult {
    try mutate(id, expectedRevision: expectedRevision) { record in
      guard record.status == .complete else {
        throw MeetingError("Text can be corrected once the transcript is complete.")
      }
      guard !changes.isEmpty, changes.count <= 200 else {
        throw MeetingError("Supply between 1 and 200 text corrections.")
      }
      var seen: Set<String> = []
      for change in changes {
        _ = try record.segmentIndex(for: change.segmentID)
        guard seen.insert(change.segmentID).inserted else {
          throw MeetingError(
            "Segment \(change.segmentID) occurs more than once in this correction.")
        }
        guard change.text.count <= 50_000, !change.text.contains("\0") else {
          throw MeetingError(
            "A corrected passage must contain at most 50,000 characters and no NUL character.")
        }
      }
      let previousSegments = record.segments
      return try record.edit { next in
        for change in changes {
          let index = try next.segmentIndex(for: change.segmentID)
          next.segments[index].text = change.text
        }
        if next.segments != previousSegments { next.summary = nil }
      }
    }
  }

  @discardableResult
  func mergeSpeakers(
    _ id: String, keep: String, merge: [String], name: String? = nil, expectedRevision: Int
  ) throws -> MeetingEditResult {
    try mutate(id, expectedRevision: expectedRevision) { record in
      guard record.status == .complete else {
        throw MeetingError("Speakers can be merged once the transcript is complete.")
      }
      let survivor = try record.speakerLabel(for: keep)
      let sources = try merge.map { try record.speakerLabel(for: $0) }
      guard !sources.isEmpty, Set(sources).count == sources.count, !sources.contains(survivor)
      else {
        throw MeetingError("Choose distinct speakers to merge into the surviving speaker.")
      }
      let labels = Set(sources + [survivor])
      let people = record.speakers.filter { labels.contains($0.label) }
      let assignedNames = Set(people.compactMap(\.name).map(Self.normalized))
      let suppliedName = try Self.validatedSpeakerName(name)
      guard assignedNames.count <= 1 || suppliedName != nil else {
        throw MeetingError("These speakers have different assigned names. Supply the name to keep.")
      }
      return try record.edit { next in
        for index in next.segments.indices where sources.contains(next.segments[index].speaker) {
          next.segments[index].speaker = survivor
        }
        next.speakers.removeAll { sources.contains($0.label) }
        guard let index = next.speakers.firstIndex(where: { $0.label == survivor }) else {
          throw MeetingError("The surviving speaker is missing.")
        }
        if let suppliedName {
          next.speakers[index].name = suppliedName == survivor ? nil : suppliedName
        }
        if Set(people.map(\.source)).count != 1 {
          next.speakers[index].source = .mix
        }
        if Set(people.map(\.identity)).count != 1 || Set(people.map(\.isLocalUser)).count != 1
          || Set(people.map(\.participant)).count != 1 || Set(people.map(\.source)).count != 1
        {
          next.speakers[index].identity = .unidentified
          next.speakers[index].isLocalUser = false
          next.speakers[index].participant = nil
        }
        let spoken = next.segments.filter { $0.speaker == survivor }
        next.speakers[index].turns = spoken.count
        next.speakers[index].seconds = MeetingRecord.seconds(
          spoken.reduce(0) { $0 + max(0, $1.end - $1.start) })
        next.orderSpeakers()
        next.summary = nil
      }
    }
  }

  @discardableResult
  func updateMeeting(
    _ id: String, title: String?? = nil, names: [String: String?]? = nil, summary: String? = nil,
    expectedRevision: Int? = nil, titleSource: MeetingTitleSource = .user
  ) throws -> MeetingEditResult {
    try mutate(id, expectedRevision: expectedRevision) { record in
      guard !record.status.isInProgress else {
        throw MeetingError(
          "This meeting is still \(record.status.rawValue); edit it once it is finished.")
      }
      guard names == nil || record.status == .complete else {
        throw MeetingError("Speakers can be named once the transcript is complete.")
      }
      if let summary {
        guard record.status == .complete, !record.segments.isEmpty else {
          throw MeetingError("A summary needs a completed, nonempty transcript.")
        }
        guard summary.count <= 1000, !summary.contains("\0") else {
          throw MeetingError("Keep the summary within 1,000 characters, without NUL characters.")
        }
      }
      if let title, titleSource == .agent {
        try record.validateAgentTitle(MeetingFiles.displayTitle(title))
      }
      var resolved: [String: String?] = [:]
      if let names {
        for (reference, name) in names {
          let label = try record.speakerLabel(for: reference)
          guard resolved.index(forKey: label) == nil else {
            throw MeetingError("Speaker \"\(label)\" occurs more than once in this change.")
          }
          let cleaned = try Self.validatedSpeakerName(name)
          resolved[label] = .some(cleaned == label ? nil : cleaned)
        }
      }
      let previousSpeakers = record.speakers
      return try record.edit { next in
        if let title {
          next.title = MeetingFiles.displayTitle(title)
          next.titleSource = next.title == nil ? .none : titleSource
        }
        for index in next.speakers.indices {
          if let value = resolved[next.speakers[index].label] { next.speakers[index].name = value }
        }
        if next.speakers != previousSpeakers { next.summary = nil }
        if let summary {
          let cleaned = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
          next.summary = cleaned.isEmpty ? nil : cleaned
        }
      }
    }
  }

  static func validatedSpeakerName(_ name: String?) throws -> String? {
    let cleaned = TranscriptDocument.cleanedName(name)
    if let cleaned, cleaned.rangeOfCharacter(from: .newlines) != nil || cleaned.contains("\0") {
      throw MeetingError("A speaker name must be a single line without NUL characters.")
    }
    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cleaned == nil {
      throw MeetingError("A speaker name cannot contain a colon.")
    }
    return cleaned
  }
}

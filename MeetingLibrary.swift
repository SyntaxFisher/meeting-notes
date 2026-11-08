import Darwin
import Foundation

/// A compact view of a meeting for listings and agents. Paths are absolute and nil when the file
/// no longer exists, for example after retention removed old audio.
struct MeetingSummary: Codable, Equatable, Sendable {
  var id: String
  var title: String?
  var startedAt: Date
  var endedAt: Date?
  var durationSeconds: Double?
  var source: MeetingSource?
  var trigger: MeetingTrigger?
  var status: MeetingStatus
  var stage: String?
  var progress: Double?
  var error: String?
  var failedAt: Date?
  var canRetry: Bool?
  var speakers: [MeetingSpeaker]
  var participants: [String]
  var segmentCount: Int
  var wordCount: Int
  var audioPath: String?
  var transcriptPath: String?
  var recordPath: String?
  /// Opens the meeting in the Library; works only on this Mac.
  var url: String

  enum CodingKeys: String, CodingKey {
    case id, title
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case durationSeconds = "duration_seconds"
    case source, trigger, status, stage, progress, error
    case failedAt = "failed_at"
    case canRetry = "can_retry"
    case speakers, participants
    case segmentCount = "segment_count"
    case wordCount = "word_count"
    case audioPath = "audio_path"
    case transcriptPath = "transcript_path"
    case recordPath = "record_path"
    case url
  }
}

struct SearchHit: Codable, Equatable, Sendable {
  var meetingId: String
  var meetingTitle: String?
  var meetingStartedAt: Date
  var start: Double
  var end: Double
  var timestamp: String
  var speaker: String
  var text: String
  var segmentID: String
  var revision: Int
  /// Opens the meeting in the Library and plays this passage; works only on this Mac.
  var url: String

  enum CodingKeys: String, CodingKey {
    case meetingId = "meeting_id"
    case meetingTitle = "meeting_title"
    case meetingStartedAt = "meeting_started_at"
    case segmentID = "segment_id"
    case revision
    case start, end, timestamp, speaker, text, url
  }
}

enum TranscriptFormat: String, CaseIterable, Sendable {
  case markdown, text, json
}

/// The read model of the meetings folder, shared by the library window, the panel, the command
/// line and the MCP server. Every meeting is described by its record, `transcripts/<id>.json`.
/// Reads work without the app running.
final class MeetingLibrary {
  let root: URL
  var timeZone: TimeZone = .current
  /// Moves a file to the Trash; tests replace it to keep the user's Trash untouched.
  var trash: (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }
  private var recordCache: [URL: (stamp: FileStamp, record: MeetingRecord?)] = [:]

  private struct FileStamp: Equatable {
    let modified: Date?
    let size: Int?

    init?(_ url: URL) {
      guard
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      else { return nil }
      modified = values.contentModificationDate
      size = values.fileSize
    }
  }

  init(root: URL = MeetingFiles.root) {
    self.root = root
  }

  var audios: URL { root.appendingPathComponent("audios", isDirectory: true) }
  var transcripts: URL { root.appendingPathComponent("transcripts", isDirectory: true) }

  func recordURL(for id: String) -> URL { MeetingFiles.record(for: id, in: transcripts) }
  func captureURL(for id: String) -> URL { MeetingFiles.capture(for: id, in: audios) }

  func audioURL(of record: MeetingRecord) -> URL? {
    let names = [record.audioFile, MeetingFiles.audio(for: record.id).lastPathComponent]
    return names.compactMap { $0 }.map { audios.appendingPathComponent($0) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  func transcriptURL(of record: MeetingRecord) -> URL? {
    let names = [record.transcriptFile, MeetingFiles.transcript(for: record.id).lastPathComponent]
    return names.compactMap { $0 }.map { transcripts.appendingPathComponent($0) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// What Retry can use for a meeting that did not finish.
  func work(for record: MeetingRecord) -> MeetingWork {
    let capture = captureURL(for: record.id)
    return MeetingWork(
      audio: audioURL(of: record),
      capture: FileManager.default.fileExists(atPath: capture.path) ? capture : nil)
  }

  // MARK: Scanning

  /// Every meeting, newest first.
  func meetings() -> [MeetingRecord] {
    contents(of: transcripts).compactMap { file -> MeetingRecord? in
      let name = file.lastPathComponent
      guard let id = MeetingFiles.id(fromFileName: name), name == id + ".json" else { return nil }
      return record(at: file)
    }.sorted(by: Self.newestFirst)
  }

  static func newestFirst(_ lhs: MeetingRecord, _ rhs: MeetingRecord) -> Bool {
    lhs.startedAt != rhs.startedAt
      ? lhs.startedAt > rhs.startedAt
      : lhs.id.compare(rhs.id, options: .numeric) == .orderedDescending
  }

  /// Meetings that still need a decision: failed, interrupted or untranscribed, oldest first.
  func needingAttention() -> [MeetingRecord] {
    meetings().filter(\.status.needsAttention).reversed()
  }

  /// Unfinished meetings among `meetings` that have a record file.
  func recoverable(_ meetings: [MeetingRecord]) -> [MeetingRecord] {
    meetings.filter {
      $0.status != .complete
        && FileManager.default.fileExists(atPath: recordURL(for: $0.id).path)
    }
  }

  /// Loads a meeting by exact id.
  func load(_ id: String) throws -> MeetingRecord {
    let file = recordURL(for: id)
    if FileManager.default.fileExists(atPath: file.path) {
      guard let record = record(at: file) else {
        throw MeetingError("\(file.path) is not a Meeting Notes record.")
      }
      return record
    }
    if let meeting = meetings().first(where: { $0.id == id }) { return meeting }
    throw MeetingError("No meeting with id \"\(id)\".")
  }

  /// Resolves an id, a unique id prefix, a unique title fragment, or `latest`.
  func resolve(_ reference: String) throws -> String {
    try Self.resolve(reference, in: meetings())
  }

  /// Resolves a reference against meetings that were already read, newest first.
  static func resolve(_ reference: String, in all: [MeetingRecord]) throws -> String {
    let trimmed = reference.trimmingCharacters(in: .whitespaces)
    if all.contains(where: { $0.id == trimmed }) { return trimmed }
    if ["latest", "last", "newest"].contains(trimmed.lowercased()) {
      if let newest = all.first(where: { $0.status == .complete }) { return newest.id }
      throw MeetingError("There are no completed meetings yet.")
    }
    let prefixed = all.filter { $0.id.hasPrefix(trimmed) }
    if prefixed.count == 1 { return prefixed[0].id }
    let needle = Self.normalized(trimmed)
    let matches =
      prefixed.isEmpty
      ? all.filter { Self.normalized($0.title ?? "").contains(needle) } : prefixed
    if matches.count == 1 { return matches[0].id }
    if matches.isEmpty {
      throw MeetingError("No meeting matches \"\(reference)\". Use list to see meeting ids.")
    }
    throw MeetingError(
      "\"\(reference)\" matches \(matches.count) meetings: "
        + matches.prefix(5).map { "\($0.id) \"\($0.displayTitle)\"" }.joined(separator: ", ")
        + (matches.count > 5 ? ", ..." : "") + ". Use an exact meeting ID or unique title.")
  }

  /// Meetings newest first. With queries, a meeting matches when any query matches its title,
  /// speaker or participant names or transcript.
  func list(
    since: Date? = nil, until: Date? = nil, queries: [String] = [],
    status: Set<MeetingStatus>? = nil, limit: Int? = nil
  ) -> [MeetingRecord] {
    let alternatives = Self.alternatives(queries)
    var result: [MeetingRecord] = []
    for record in meetings() {
      if let limit, result.count >= limit { break }
      if let since, record.startedAt < since { continue }
      if let until, record.startedAt >= until { continue }
      if let status, !status.contains(record.status) { continue }
      if !alternatives.isEmpty, Self.firstMatch(alternatives, in: haystack(of: record)) == nil {
        continue
      }
      result.append(record)
    }
    return result
  }

  /// Whether every query word starts a word of the title, a speaker or participant name, or the
  /// transcript, ignoring case and diacritics.
  func matches(_ record: MeetingRecord, query: String) -> Bool {
    let terms = Self.terms(query)
    return terms.isEmpty || Self.matches(terms, in: haystack(of: record))
  }

  private func haystack(of record: MeetingRecord) -> String {
    ([record.id, record.title ?? ""] + record.speakers.map(\.displayName)
      + (record.participants?.participants.map(\.name) ?? []) + record.segments.map(\.text))
      .joined(separator: "\n")
  }

  /// Finds transcript segments matching any of the queries. A query matches when each of its
  /// terms starts a word, ignoring case and diacritics, so "budget" finds "budgets" but "mac"
  /// does not find "gemacht". Meetings are searched newest first; segments within a meeting in
  /// spoken order.
  func search(
    _ queries: [String], since: Date? = nil, until: Date? = nil, meeting: String? = nil,
    limit: Int = 20
  ) -> [SearchHit] {
    let alternatives = Self.alternatives(queries)
    guard !alternatives.isEmpty else { return [] }
    var hits: [SearchHit] = []
    let candidates = meeting.flatMap { try? load($0) }.map { [$0] } ?? meetings()
    for record in candidates {
      if let since, record.startedAt < since { continue }
      if let until, record.startedAt >= until { continue }
      for (index, segment) in record.segments.enumerated() {
        let speaker = record.displayName(for: segment.speaker)
        guard let terms = Self.firstMatch(alternatives, in: segment.text + "\n" + speaker)
        else { continue }
        hits.append(
          SearchHit(
            meetingId: record.id, meetingTitle: record.title,
            meetingStartedAt: record.startedAt, start: segment.start, end: segment.end,
            timestamp: Self.timestamp(segment.start), speaker: speaker,
            text: Self.snippet(segment.text, around: terms[0]),
            segmentID: record.segmentID(at: index), revision: record.revision,
            url: record.link(to: segment).string))
        if hits.count >= limit { return hits }
      }
    }
    return hits
  }

  func summary(of record: MeetingRecord) -> MeetingSummary {
    let recordFile = recordURL(for: record.id)
    return MeetingSummary(
      id: record.id, title: record.title, startedAt: record.startedAt, endedAt: record.endedAt,
      durationSeconds: record.durationSeconds, source: record.source, trigger: record.trigger,
      status: record.status, stage: record.stage, progress: record.progress, error: record.error,
      failedAt: record.failedAt,
      canRetry: record.status.needsAttention ? work(for: record).canRetry : nil,
      speakers: record.speakers,
      participants: record.participants?.participants.map(\.name) ?? [],
      segmentCount: record.segments.count,
      wordCount: record.segments.reduce(0) {
        $0 + $1.text.split(whereSeparator: \.isWhitespace).count
      },
      audioPath: audioURL(of: record)?.path, transcriptPath: transcriptURL(of: record)?.path,
      recordPath: FileManager.default.fileExists(atPath: recordFile.path) ? recordFile.path : nil,
      url: record.link.string)
  }

  // MARK: Editing

  /// Writes the record atomically. A file that is not a Meeting Notes record is never replaced.
  func save(_ record: MeetingRecord) throws {
    try withRecordLock(record.id) {
      recordCache[recordURL(for: record.id)] = nil
      if FileManager.default.fileExists(atPath: recordURL(for: record.id).path) {
        let current = try load(record.id)
        guard current.revision == record.revision
        else {
          throw MeetingError(
            "This meeting was edited elsewhere. Read revision \(current.revision) before saving.")
        }
        if current.status == .complete,
          current.segments != record.segments || current.speakers != record.speakers
            || current.title != record.title
        {
          throw MeetingError("Use a transcript edit to change a completed meeting.")
        }
      }
      try persist(record)
    }
  }

  private func persist(_ record: MeetingRecord) throws {
    var record = record
    record.updatedAt = Date()
    let file = recordURL(for: record.id)
    if FileManager.default.fileExists(atPath: file.path), self.record(at: file) == nil {
      throw MeetingError(
        "\(file.path) exists and is not a Meeting Notes record; it was not changed.")
    }
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try JSONCoding.encoder(pretty: true).encode(record).write(to: file, options: .atomic)
    recordCache[file] = nil
  }

  /// The lock has its own stable inode because records are replaced atomically.
  private func withRecordLock<T>(_ id: String, _ body: () throws -> T) throws -> T {
    guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
      !id.contains("\0")
    else { throw MeetingError("Invalid meeting id.") }
    let directory = transcripts.appendingPathComponent(".edit-locks", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(id + ".lock")
    let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }

  func mutate(
    _ id: String, expectedRevision: Int?, _ body: (inout MeetingRecord) throws -> Bool
  ) throws -> MeetingEditResult {
    try withRecordLock(id) {
      recordCache[recordURL(for: id)] = nil
      var record = try load(id)
      if let expectedRevision, expectedRevision != record.revision {
        throw MeetingEditConflict.revision(expected: expectedRevision, current: record.revision)
      }
      let previous = record
      let changed = try body(&record)
      if changed {
        record.updatedAt = Date()
        try persist(record)
        if let transcript = transcriptURL(of: record) {
          do {
            try Data(Self.transcriptText(record).utf8).write(to: transcript, options: .atomic)
          } catch {
            try persist(previous)
            throw error
          }
        }
      }
      return MeetingEditResult(record: record, changed: changed)
    }
  }

  /// Assigns display names to speaker labels. A nil or empty name clears it. Labels may be given
  /// as `Speaker 2` or just `2`.
  @discardableResult
  func renameSpeakers(_ id: String, names: [String: String?]) throws -> MeetingRecord {
    try updateMeeting(id, names: names).record
  }

  /// Retitles a finished meeting. File names contain only its id, so no file changes name.
  @discardableResult
  func setTitle(_ id: String, title: String?, titleSource: MeetingTitleSource = .user) throws
    -> MeetingRecord
  {
    try updateMeeting(id, title: .some(title), titleSource: titleSource).record
  }

  /// Every file and folder of a meeting: all files in both folders named `<id>.<anything>`, and
  /// its capture folder.
  func files(of id: String) -> [URL] {
    var files: [URL] = []
    for directory in [transcripts, audios] {
      for file in contents(of: directory) where !file.lastPathComponent.hasPrefix(".") {
        if MeetingFiles.id(fromFileName: file.lastPathComponent) == id { files.append(file) }
      }
    }
    let capture = captureURL(for: id)
    if FileManager.default.fileExists(atPath: capture.path) { files.append(capture) }
    return files
  }

  /// Moves every file of the meeting to the Trash and returns where each one was.
  @discardableResult
  func moveToTrash(_ id: String) throws -> [URL] {
    try withRecordLock(id) {
      var trashed: [URL] = []
      for file in files(of: id) {
        try trash(file)
        trashed.append(file)
      }
      recordCache[recordURL(for: id)] = nil
      return trashed
    }
  }

  // MARK: Rendering

  func render(_ record: MeetingRecord, as format: TranscriptFormat) throws -> String {
    switch format {
    case .json:
      return String(
        decoding: try JSONCoding.encoder(pretty: true).encode(try Self.json(record)), as: UTF8.self)
    case .text: return Self.transcriptText(record)
    case .markdown: return markdown(record)
    }
  }

  /// The record as JSON with a `url` for the meeting and for each segment.
  static func json(_ record: MeetingRecord) throws -> JSONValue {
    guard case .object(var object) = try JSONValue.from(record) else { return .null }
    object["url"] = .string(record.link.string)
    if case .array(let segments) = object["segments"] {
      object["segments"] = .array(
        zip(segments, record.segments).enumerated().map { index, pair in
          let (value, segment) = pair
          guard case .object(var fields) = value else { return value }
          fields["segment_id"] = .string(record.segmentID(at: index))
          fields["url"] = .string(record.link(to: segment).string)
          return .object(fields)
        })
    }
    return .object(object)
  }

  /// The transcript lines with assigned speaker names.
  static func transcriptText(_ record: MeetingRecord) -> String {
    record.segments.map {
      "[\(timestamp($0.start))] \(record.displayName(for: $0.speaker)): \($0.text)"
    }.joined(separator: "\n\n") + (record.segments.isEmpty ? "" : "\n")
  }

  /// Markdown with YAML front matter, rendered from the record so it always reflects current
  /// titles and names.
  func markdown(_ record: MeetingRecord) -> String {
    let summary = summary(of: record)
    var front: [String] = ["---"]
    func line(_ key: String, _ value: String?) {
      if let value { front.append("\(key): \(value)") }
    }
    line("id", Self.yamlString(record.id))
    line("revision", String(record.revision))
    line("title", record.title.map(Self.yamlString))
    line("started_at", JSONCoding.formatDate(record.startedAt, timeZone: timeZone))
    line("ended_at", record.endedAt.map { JSONCoding.formatDate($0, timeZone: timeZone) })
    line("duration_seconds", record.durationSeconds.map { String(Int($0.rounded())) })
    line("source", record.source?.rawValue)
    line("trigger", record.trigger?.rawValue)
    line("status", record.status.rawValue)
    line("error", record.error.map(Self.yamlString))
    if !record.speakers.isEmpty {
      front.append("speakers:")
      for speaker in record.speakers {
        front.append("  - label: \(Self.yamlString(speaker.label))")
        if let name = speaker.name { front.append("    name: \(Self.yamlString(name))") }
        if speaker.isLocalUser { front.append("    local_user: true") }
      }
    }
    if let participants = record.participants?.participants, !participants.isEmpty {
      front.append("teams_participants:")
      for participant in participants {
        front.append("  - \(Self.yamlString(participant.name))")
      }
    }
    line("url", Self.yamlString(summary.url))
    line("transcript_path", summary.transcriptPath.map(Self.yamlString))
    line("audio_path", summary.audioPath.map(Self.yamlString))
    front.append("---")
    var body = "\n# \(record.displayTitle)\n\n"
    switch record.status {
    case .complete:
      body += "Speaker labels come from automatic voice detection and may be inaccurate. "
      body += "Timestamps link to the audio in Meeting Notes and work only on this Mac.\n\n"
      body += record.segments.map {
        "[\(Self.timestamp($0.start))](\(record.link(to: $0).string)) **\(record.displayName(for: $0.speaker)):** \($0.text)"
      }.joined(separator: "\n\n")
      body += "\n"
    case .failed, .interrupted:
      body += "_Needs attention: \(record.error ?? "unknown error")_\n"
    case .untranscribed: body += "_This recording has no transcript._\n"
    case .recording, .saving, .queued, .transcribing:
      body += "_\(record.status.rawValue.capitalized)._\n"
    }
    return front.joined(separator: "\n") + "\n" + body
  }

  static func groupedByDay(_ records: [MeetingRecord], calendar: Calendar = .current)
    -> [(day: Date, records: [MeetingRecord])]
  {
    var groups: [(day: Date, records: [MeetingRecord])] = []
    for record in records {
      let day = calendar.startOfDay(for: record.startedAt)
      if groups.last?.day == day {
        groups[groups.count - 1].records.append(record)
      } else {
        groups.append((day, [record]))
      }
    }
    return groups
  }

  // MARK: Files

  private func contents(of directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
  }

  private func record(at file: URL) -> MeetingRecord? {
    guard let stamp = FileStamp(file) else { return nil }
    if let cached = recordCache[file], cached.stamp == stamp { return cached.record }
    let record = (try? Data(contentsOf: file)).flatMap {
      try? JSONCoding.decoder().decode(MeetingRecord.self, from: $0)
    }
    recordCache[file] = (stamp, record)
    return record
  }

  // MARK: Text helpers

  /// Parses `[HH:MM:SS] Label: text` lines. A segment ends where the next one starts; the last
  /// one has zero length because its end is unknown. Header lines before the first turn are
  /// skipped, and other lines continue the previous turn.
  static func parseTranscript(_ text: String) -> [MeetingSegment] {
    var segments: [MeetingSegment] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let match = line.firstMatch(of: #/^\[(\d+):(\d{2}):(\d{2})\] ([^:]{1,80}): ?(.*)$/#),
        let hours = Double(match.1), let minutes = Double(match.2),
        let seconds = Double(match.3)
      else {
        if !segments.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
          segments[segments.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
        }
        continue
      }
      let start = hours * 3600 + minutes * 60 + seconds
      if !segments.isEmpty { segments[segments.count - 1].end = start }
      segments.append(
        MeetingSegment(start: start, end: start, speaker: String(match.4), text: String(match.5)))
    }
    return segments
  }

  static func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
  }

  static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  static func words(_ text: String) -> [Substring] {
    normalized(text).split { !$0.isLetter && !$0.isNumber }
  }

  static func terms(_ query: String?) -> [String] {
    guard let query else { return [] }
    return words(query).map(String.init)
  }

  static func alternatives(_ queries: [String]) -> [[String]] {
    queries.map(terms).filter { !$0.isEmpty }
  }

  static func matches(_ terms: [String], in text: String) -> Bool {
    firstMatch([terms], in: text) != nil
  }

  static func firstMatch(_ alternatives: [[String]], in text: String) -> [String]? {
    let words = words(text)
    return alternatives.first { terms in
      terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }
  }

  static func label(_ label: String, matches reference: String) -> Bool {
    let reference = reference.trimmingCharacters(in: .whitespaces)
    if label.caseInsensitiveCompare(reference) == .orderedSame { return true }
    return Int(reference) != nil
      && label.caseInsensitiveCompare("Speaker \(reference)") == .orderedSame
  }

  /// Shortens long segments to about 240 characters around the first match.
  static func snippet(_ text: String, around term: String, radius: Int = 120) -> String {
    guard text.count > radius * 2 else { return text }
    let offset =
      text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
      .map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
    let startOffset = max(0, offset - radius)
    let endOffset = min(text.count, offset + radius)
    let start = text.index(text.startIndex, offsetBy: startOffset)
    let end = text.index(text.startIndex, offsetBy: endOffset)
    return (startOffset > 0 ? "..." : "") + text[start..<end]
      + (endOffset < text.count ? "..." : "")
  }

  static func yamlString(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }
}

import AVFoundation
import Darwin
import Foundation

/// Renames meetings saved by earlier versions to the current `<id>.<extension>` files.
///
/// Earlier versions named every file `yyyy-MM-dd HH.mm[-N][ Title].<extension>` in local time.
/// Version 2.0 kept a record at `<old id>.json`; 1.x had none, so the migration creates the
/// record from the transcript, the audio or the capture folder, keeping the title that only the
/// file name held. Each file gets the new id in place of its old stem and keeps what followed
/// it, such as `.summary.md`. Nothing is overwritten: when that name is taken, or would be the
/// record name `<id>.json` for another file, the file becomes `<id>.legacy.<extension>` (then
/// `legacy-2`, ...). The planned ids are saved before any file moves and kept until every file
/// of a meeting has moved, so an interrupted or incomplete migration continues with the same ids.
enum MeetingFilesMigration {
  struct Result: Equatable {
    var migrated: [String: String] = [:]
    var skipped: [String] = []
  }

  private struct Entry: Codable, Equatable {
    var id: String
    var title: String?
  }

  private struct Group {
    var files: [URL] = []
    var capture: URL?
  }

  /// Whether files in an earlier format or an unfinished migration plan remain.
  static func isNeeded(root: URL) -> Bool {
    let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
    let audios = root.appendingPathComponent("audios", isDirectory: true)
    return !scan(transcripts, audios).isEmpty
      || FileManager.default.fileExists(atPath: planFile(in: transcripts).path)
  }

  private static func planFile(in transcripts: URL) -> URL {
    transcripts.appendingPathComponent(".edit-locks/migration-plan.json")
  }

  static func run(root: URL, timeZone: TimeZone = .current) throws -> Result {
    let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
    let audios = root.appendingPathComponent("audios", isDirectory: true)
    let state = transcripts.appendingPathComponent(".edit-locks", isDirectory: true)
    let planFile = Self.planFile(in: transcripts)
    let manager = FileManager.default
    guard isNeeded(root: root) else { return Result() }
    try manager.createDirectory(at: state, withIntermediateDirectories: true)
    return try withLock(state.appendingPathComponent("migration.lock")) {
      let groups = scan(transcripts, audios)
      var plan =
        (try? Data(contentsOf: planFile)).flatMap {
          try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
      let names = Set([transcripts, audios].flatMap(contents))
      for old in groups.keys.sorted() where plan[old] == nil {
        let group = groups[old]!
        let record = record(at: transcripts.appendingPathComponent(old + ".json"))
        guard let startedAt = record?.startedAt ?? date(fromOldID: old, timeZone: timeZone)
        else { continue }
        let planned = Set(plan.values.map(\.id))
        let id = MeetingFiles.id(startingAt: startedAt) { candidate in
          planned.contains(candidate)
            || names.contains { $0 == ".\(candidate).recording" || $0.hasPrefix(candidate + ".") }
        }
        plan[old] = Entry(
          id: id, title: record == nil ? title(of: group, old: old) : nil)
      }
      guard !plan.isEmpty else { return Result() }
      try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)

      var result = Result()
      for old in plan.keys.sorted() {
        let entry = plan[old]!
        let skipped = migrate(
          old: old, to: entry, group: groups[old] ?? Group(), transcripts: transcripts,
          audios: audios, timeZone: timeZone)
        result.migrated[old] = entry.id
        result.skipped += skipped
        if skipped.isEmpty {
          plan[old] = nil
          try? manager.removeItem(at: state.appendingPathComponent(old + ".lock"))
        }
      }
      if plan.isEmpty {
        try manager.removeItem(at: planFile)
      } else {
        try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
      }
      return result
    }
  }

  // MARK: Steps

  /// Moves one meeting's files and writes its record. Returns the paths that could not move.
  private static func migrate(
    old: String, to entry: Entry, group: Group, transcripts: URL, audios: URL,
    timeZone: TimeZone
  ) -> [String] {
    let manager = FileManager.default
    var skipped: [String] = []
    let oldRecordFile = transcripts.appendingPathComponent(old + ".json")
    let newRecordFile = MeetingFiles.record(for: entry.id, in: transcripts)
    let existing = record(at: oldRecordFile)
    var stems = [old]
    stems += [existing?.audioFile, existing?.transcriptFile].compactMap { $0 }.map(stem)
    stems += group.files.filter { ["txt", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
      .map { stem($0.lastPathComponent) }
    stems = Array(Set(stems)).sorted { $0.count > $1.count }

    /// What follows the old stem, such as `.summary.md`, or "" for a name without extension.
    func suffix(_ name: String) -> String {
      if let stem = stems.first(where: { name.hasPrefix($0 + ".") }) {
        return String(name.dropFirst(stem.count))
      }
      let rest = name.dropFirst(old.count)
      return rest.firstIndex(of: ".").map { String(rest[$0...]) } ?? ""
    }
    /// The record's own files move first, so they get the plain names.
    let owned = [existing?.transcriptFile, existing?.audioFile].compactMap { $0 }
    let files = group.files.filter { $0 != oldRecordFile }.sorted {
      let (lhs, rhs) = ($0.lastPathComponent, $1.lastPathComponent)
      return owned.contains(lhs) != owned.contains(rhs) ? owned.contains(lhs) : lhs < rhs
    }
    var moved: [String: String] = [:]
    for file in files {
      let folder = file.deletingLastPathComponent()
      let suffix = suffix(file.lastPathComponent)
      var candidates = suffix.isEmpty || suffix == ".json" ? [] : [entry.id + suffix]
      candidates += (["legacy"] + (2...99).map { "legacy-\($0)" }).map {
        "\(entry.id).\($0)\(suffix)"
      }
      guard
        let name = candidates.first(where: {
          !manager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }),
        (try? manager.moveItem(at: file, to: folder.appendingPathComponent(name))) != nil
      else {
        skipped.append(file.path)
        continue
      }
      moved[file.lastPathComponent] = name
    }
    func newName(_ name: String) -> String { moved[name] ?? entry.id + suffix(name) }

    if let capture = group.capture {
      do {
        try manager.moveItem(at: capture, to: MeetingFiles.capture(for: entry.id, in: audios))
      } catch {
        skipped.append(capture.path)
      }
    }

    if manager.fileExists(atPath: oldRecordFile.path) {
      guard var record = existing else { return skipped + [oldRecordFile.path] }
      if !manager.fileExists(atPath: newRecordFile.path) {
        record.id = entry.id
        record.audioFile = record.audioFile.map(newName)
        record.transcriptFile = record.transcriptFile.map(newName)
        guard (try? publish(record, to: newRecordFile)) != nil else {
          return skipped + [oldRecordFile.path]
        }
      }
      try? manager.removeItem(at: oldRecordFile)
    } else if !manager.fileExists(atPath: newRecordFile.path),
      let startedAt = date(fromOldID: old, timeZone: timeZone),
      let record = createdRecord(
        entry, startedAt: startedAt, transcripts: transcripts, audios: audios)
    {
      if (try? publish(record, to: newRecordFile)) == nil { skipped.append(newRecordFile.path) }
    }
    return skipped
  }

  /// The record 2.0 showed for a meeting from 1.x: a complete meeting for a transcript,
  /// `untranscribed` for audio alone, and `interrupted` for a capture folder alone.
  private static func createdRecord(
    _ entry: Entry, startedAt: Date, transcripts: URL, audios: URL
  ) -> MeetingRecord? {
    let manager = FileManager.default
    let transcript = MeetingFiles.transcript(for: entry.id, in: transcripts)
    let audio = ["m4a", "mp3"].map { audios.appendingPathComponent("\(entry.id).\($0)") }
      .first { manager.fileExists(atPath: $0.path) }
    let audioDuration = audio.flatMap(duration)
    if let text = try? String(contentsOf: transcript, encoding: .utf8) {
      var record = MeetingRecord(
        id: entry.id, title: entry.title, startedAt: startedAt, status: .complete)
      record.transcriptFile = transcript.lastPathComponent
      record.audioFile = audio?.lastPathComponent
      record.segments = MeetingLibrary.parseTranscript(text)
      record.speakers = MeetingRecord.speakers(for: record.segments)
      record.durationSeconds = (audioDuration ?? record.segments.last?.end).map(
        MeetingRecord.seconds)
      record.endedAt = record.durationSeconds.map { startedAt.addingTimeInterval($0) }
      return record
    }
    if let audio {
      var record = MeetingRecord(
        id: entry.id, title: entry.title, startedAt: startedAt, status: .untranscribed)
      record.audioFile = audio.lastPathComponent
      record.durationSeconds = audioDuration
      return record
    }
    if manager.fileExists(atPath: MeetingFiles.capture(for: entry.id, in: audios).path) {
      var record = MeetingRecord(
        id: entry.id, title: entry.title, startedAt: startedAt, status: .interrupted)
      record.error = "The recording was interrupted before its audio was saved."
      return record
    }
    return nil
  }

  // MARK: Old names

  /// The meetings with files in the old format, by old id.
  private static func scan(_ transcripts: URL, _ audios: URL) -> [String: Group] {
    var groups: [String: Group] = [:]
    for directory in [transcripts, audios] {
      for name in contents(directory) {
        let file = directory.appendingPathComponent(name)
        if directory == audios,
          let match = name.wholeMatch(
            of: #/\.(\d{4}-\d{2}-\d{2} \d{2}\.\d{2}(?:-\d+)?)\.recording/#)
        {
          groups[String(match.1), default: Group()].capture = file
        } else if let match = name.firstMatch(
          of: #/^(\d{4}-\d{2}-\d{2} \d{2}\.\d{2}(?:-\d+)?)[ .]/#)
        {
          groups[String(match.1), default: Group()].files.append(file)
        }
      }
    }
    return groups
  }

  private static func date(fromOldID id: String, timeZone: TimeZone) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH.mm"
    return formatter.date(from: String(id.prefix(16)))
  }

  /// The title a 1.x meeting had only in its file names, from its transcript or else its audio.
  private static func title(of group: Group, old: String) -> String? {
    let primary =
      group.files.first { $0.pathExtension.lowercased() == "txt" }
      ?? group.files.first { ["m4a", "mp3"].contains($0.pathExtension.lowercased()) }
    guard let primary else { return nil }
    return MeetingFiles.displayTitle(String(stem(primary.lastPathComponent).dropFirst(old.count)))
  }

  private static func stem(_ name: String) -> String {
    (name as NSString).deletingPathExtension
  }

  // MARK: Files

  private static func contents(_ directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
  }

  private static func record(at file: URL) -> MeetingRecord? {
    (try? Data(contentsOf: file)).flatMap {
      try? JSONCoding.decoder().decode(MeetingRecord.self, from: $0)
    }
  }

  private static func publish(_ record: MeetingRecord, to file: URL) throws {
    try MeetingFiles.publish(JSONCoding.encoder(pretty: true).encode(record), to: file)
  }

  private static func duration(_ file: URL) -> Double? {
    (try? AVAudioFile(forReading: file)).map {
      MeetingRecord.seconds(Double($0.length) / $0.processingFormat.sampleRate)
    }
  }

  private static func withLock<T>(_ file: URL, _ body: () throws -> T) throws -> T {
    let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }
}

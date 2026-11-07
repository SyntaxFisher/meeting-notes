import Foundation

/// Removes old audio above its budget, preserving the newest and protected recordings.
/// Transcripts and their records are never removed by retention.
enum RecordingRetention {
  static let audioLimit: Int64 = 10_000_000_000

  struct Usage: Equatable, Sendable {
    var audioBytes: Int64 = 0
    var transcriptBytes: Int64 = 0
  }

  private struct Unit {
    let id: String
    let date: Date
    var files: [URL] = []
    var size: Int64 = 0
    /// Audio in `audios/`, a transcript in `transcripts/`. Meetings without one are never pruned.
    var hasPrimary = false

    var deletion: Deletion { Deletion(id: id, date: date, bytes: size, files: files) }
  }

  /// The files of one meeting in one folder that retention selected.
  struct Deletion: Equatable, Sendable {
    let id: String
    let date: Date
    let bytes: Int64
    let files: [URL]
  }

  /// What `enforce` deletes with the given budgets, in deletion order.
  struct Plan: Equatable, Sendable {
    /// The oldest recordings above the audio budget.
    var audios: [Deletion] = []

    var isEmpty: Bool { audios.isEmpty }
    var files: [URL] { audios.flatMap(\.files) }
    var bytes: Int64 { audios.reduce(0) { $0 + $1.bytes } }
    var oldest: Date? { audios.map(\.date).min() }

    /// One sentence for a confirmation, such as "This permanently deletes 12 recordings
    /// (3.4 GB), the oldest from 2026-09-01."
    var summary: String {
      let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      var sentence = "This permanently deletes \(count(audios.count, "recording")) (\(size))"
      if let oldest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        sentence += ", the oldest from \(formatter.string(from: oldest))"
      }
      return sentence + "."
    }

    private func count(_ value: Int, _ noun: String) -> String {
      value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }
  }

  /// Deletes the oldest eligible recordings until the audio budget fits and returns the files
  /// that were removed.
  @discardableResult
  static func enforce(
    root: URL, protected: Set<String> = [], audioBudget: Int64 = audioLimit
  ) throws -> [URL] {
    let plan = try plan(
      root: root, protected: protected, audioBudget: audioBudget)
    var removed: [URL] = []
    for file in plan.files {
      try FileManager.default.removeItem(at: file)
      removed.append(file)
      AppLog.event("retention.deleted", file.path)
    }
    AppLog.event(
      "retention.complete",
      "audios=\(plan.audios.count); bytes=\(plan.bytes)")
    return removed
  }

  /// Selects recordings to remove without changing any files.
  static func plan(
    root: URL, protected: Set<String> = [], audioBudget: Int64 = audioLimit
  ) throws -> Plan {
    let audios = try units(in: root.appendingPathComponent("audios"), primary: ["m4a", "mp3"])
    return Plan(audios: select(audios, budget: audioBudget, protected: protected).map(\.deletion))
  }

  /// Explicit audio removal includes the newest completed meeting and leaves transcripts intact.
  static func removeCompletedAudio(root: URL, completed: Set<String>) throws {
    let audios = try units(in: root.appendingPathComponent("audios"), primary: ["m4a", "mp3"])
    for unit in audios where completed.contains(unit.id) {
      for file in unit.files where ["m4a", "mp3"].contains(file.pathExtension.lowercased()) {
        try FileManager.default.removeItem(at: file)
        AppLog.event("audio.deleted", file.path)
      }
    }
  }

  /// Bytes of meeting files in each folder, using the same files retention would consider.
  static func usage(root: URL) -> Usage {
    func total(_ folder: String, _ primary: Set<String>) -> Int64 {
      ((try? units(in: root.appendingPathComponent(folder), primary: primary)) ?? [])
        .reduce(0) { $0 + $1.size }
    }
    return Usage(
      audioBytes: total("audios", ["m4a", "mp3"]), transcriptBytes: total("transcripts", ["txt"]))
  }

  private static func units(in directory: URL, primary: Set<String>) throws -> [Unit] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directory.path) else { return [] }
    var units: [String: Unit] = [:]
    for file in try manager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles])
    {
      guard let id = MeetingFiles.id(fromFileName: file.lastPathComponent),
        let date = MeetingFiles.date(fromID: id)
      else { continue }
      let attributes = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
      var unit = units[id] ?? Unit(id: id, date: date)
      unit.files.append(file)
      unit.size += Int64(attributes.fileSize ?? 0)
      unit.hasPrimary = unit.hasPrimary || primary.contains(file.pathExtension.lowercased())
      units[id] = unit
    }
    return units.values.sorted {
      $0.date != $1.date
        ? $0.date < $1.date : $0.id.compare($1.id, options: .numeric) == .orderedAscending
    }
  }

  /// The oldest meetings to delete until `ordered` fits `budget`, skipping the newest meeting
  /// with a primary file, meetings without one and protected meetings.
  private static func select(_ ordered: [Unit], budget: Int64, protected: Set<String>) -> [Unit] {
    let newest = ordered.last { $0.hasPrimary }?.id
    var total = ordered.reduce(0) { $0 + $1.size }
    var selected: [Unit] = []
    for unit in ordered {
      guard total > budget else { break }
      guard unit.hasPrimary, unit.id != newest, !protected.contains(unit.id) else { continue }
      selected.append(unit)
      total -= unit.size
    }
    return selected
  }
}

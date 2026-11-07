import Foundation

struct MeetingError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum MeetingFiles {
  /// The fixed meetings directory, or an isolated directory provided by the test harness.
  nonisolated(unsafe) static var root = AppConfig().meetingsRootURL
  static var audios: URL { root.appendingPathComponent("audios", isDirectory: true) }
  static var transcripts: URL { root.appendingPathComponent("transcripts", isDirectory: true) }
  static func ensureDirectories() throws {
    try FileManager.default.createDirectory(at: audios, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
  }
  static func stem(
    for date: Date, in audioDirectory: URL = audios, transcriptDirectory: URL = transcripts,
    timeZone: TimeZone = .current
  ) -> String {
    let base = formatter("yyyy-MM-dd HH.mm", timeZone).string(from: date)
    let names = [audioDirectory, transcriptDirectory].flatMap {
      (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
    }
    func isTaken(_ candidate: String) -> Bool {
      names.contains {
        $0 == ".\(candidate).recording" || $0.hasPrefix(candidate + ".")
          || $0.hasPrefix(candidate + " ")
      }
    }
    var candidate = base
    var suffix = 2
    while isTaken(candidate) {
      candidate = "\(base)-\(suffix)"
      suffix += 1
    }
    return candidate
  }

  /// Parses the start time from a local `yyyy-MM-dd HH.mm` stem with optional collision suffix
  /// and title, or from a legacy UTC `yyyyMMdd'T'HHmmss'Z'` stem.
  static func date(fromStem stem: String, timeZone: TimeZone = .current) -> Date? {
    if let match = stem.firstMatch(of: #/^(\d{4}-\d{2}-\d{2} \d{2}\.\d{2})(?:-\d+)?(?: .+)?$/#) {
      return formatter("yyyy-MM-dd HH.mm", timeZone).date(from: String(match.1))
    }
    if let match = stem.firstMatch(of: #/^(\d{8}T\d{6}Z)(?:-\d+)?$/#) {
      return formatter("yyyyMMdd'T'HHmmss'Z'", TimeZone(secondsFromGMT: 0)!).date(
        from: String(match.1))
    }
    return nil
  }

  /// The meeting title part of a `yyyy-MM-dd HH.mm[-N] Title` stem.
  static func title(fromStem stem: String) -> String? {
    guard let match = stem.firstMatch(of: #/^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}(?:-\d+)? (.+)$/#)
    else { return nil }
    return String(match.1)
  }

  /// Writes a new file through a staging file in the same folder. An existing destination is
  /// never replaced: the move fails instead.
  static func publish(_ data: Data, to destination: URL) throws {
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString).partial")
    defer { try? FileManager.default.removeItem(at: staging) }
    try data.write(to: staging, options: .atomic)
    try FileManager.default.moveItem(at: staging, to: destination)
  }

  /// The timestamp part of a file stem, with its collision suffix but without the title.
  static func id(fromFileStem stem: String) -> String? {
    if let match = stem.firstMatch(of: #/^(\d{4}-\d{2}-\d{2} \d{2}\.\d{2}(?:-\d+)?)(?: .+)?$/#) {
      return String(match.1)
    }
    if let match = stem.firstMatch(of: #/^(\d{8}T\d{6}Z(?:-\d+)?)$/#) { return String(match.1) }
    return nil
  }

  /// A meeting title as written, on one line, for records and every surface that shows it.
  static func displayTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let cleaned = title.components(separatedBy: .controlCharacters).joined(separator: " ")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
  }

  /// A title made safe for file names: no path separators, no leading dots, limited length.
  static func titleComponent(_ title: String?) -> String? {
    guard let title else { return nil }
    let separators = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
    var cleaned = title.components(separatedBy: separators).joined(separator: "-")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    cleaned = String(cleaned.prefix(80))
    while cleaned.utf8.count > 150 { cleaned.removeLast() }
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter
  }
  static func audio(for stem: String, in directory: URL = audios) -> URL {
    directory.appendingPathComponent(stem + ".m4a")
  }
  static func transcript(for stem: String, in directory: URL = transcripts) -> URL {
    directory.appendingPathComponent(stem + ".txt")
  }
  static func record(for id: String, in directory: URL = transcripts) -> URL {
    directory.appendingPathComponent(id + ".json")
  }
  static func capture(for id: String, in directory: URL = audios) -> URL {
    directory.appendingPathComponent("." + id + ".recording", isDirectory: true)
  }

  /// The file stem of a meeting: its id, followed by its file-safe title when it has one.
  static func fileStem(id: String, title: String?) -> String {
    titleComponent(title).map { "\(id) \($0)" } ?? id
  }

  /// The meeting id a file in the meetings folder belongs to, such as `2026-11-05 15.50` for
  /// `2026-11-05 15.50 Weekly Sync.summary.md`.
  static func id(fromFileName name: String) -> String? {
    var stem = name
    while let dot = stem.lastIndex(of: ".") {
      stem = String(stem[..<dot])
      if let id = id(fromFileStem: stem) { return id }
    }
    return nil
  }
}

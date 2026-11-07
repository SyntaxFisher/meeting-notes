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

  /// A new meeting id: the UTC start time in ISO 8601 basic format, such as `20261105T141700Z`,
  /// with `-2`, `-3`, ... when that second is already taken in either folder.
  static func id(
    startingAt date: Date, in audioDirectory: URL = audios, transcriptDirectory: URL = transcripts
  ) -> String {
    let names = Set(
      [audioDirectory, transcriptDirectory].flatMap {
        (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
      })
    return id(startingAt: date) { candidate in
      names.contains { $0 == ".\(candidate).recording" || $0.hasPrefix(candidate + ".") }
    }
  }

  static func id(startingAt date: Date, isTaken: (String) -> Bool) -> String {
    let base = idFormatter.string(from: date)
    var candidate = base
    var suffix = 2
    while isTaken(candidate) {
      candidate = "\(base)-\(suffix)"
      suffix += 1
    }
    return candidate
  }

  /// The start time encoded in a meeting id, to the second.
  static func date(fromID id: String) -> Date? {
    guard let match = id.wholeMatch(of: #/(\d{8}T\d{6}Z)(?:-[1-9]\d*)?/#) else { return nil }
    return idFormatter.date(from: String(match.1))
  }

  /// The meeting id a file in the meetings folder belongs to: `<id>.<anything>`, such as
  /// `20261105T141700Z` for `20261105T141700Z.summary.md`.
  static func id(fromFileName name: String) -> String? {
    guard let match = name.firstMatch(of: #/^(\d{8}T\d{6}Z(?:-[1-9]\d*)?)\./#) else { return nil }
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

  /// A meeting title as written, on one line, for records and every surface that shows it.
  static func displayTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let cleaned = title.components(separatedBy: .controlCharacters).joined(separator: " ")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
  }

  static func audio(for id: String, in directory: URL = audios) -> URL {
    directory.appendingPathComponent(id + ".m4a")
  }
  static func transcript(for id: String, in directory: URL = transcripts) -> URL {
    directory.appendingPathComponent(id + ".txt")
  }
  static func record(for id: String, in directory: URL = transcripts) -> URL {
    directory.appendingPathComponent(id + ".json")
  }
  static func capture(for id: String, in directory: URL = audios) -> URL {
    directory.appendingPathComponent("." + id + ".recording", isDirectory: true)
  }

  private static let idFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()
}

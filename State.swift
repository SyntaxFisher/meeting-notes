import Foundation

struct MeetingError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct MeetingSession: Codable {
  let startedAt: Date
  let stem: String
  var title: String? = nil

  var fileStem: String { title.map { "\(stem) \($0)" } ?? stem }
}

struct MeetingState: Codable {
  var session: MeetingSession? = nil
  var pendingAudio: String? = nil
  var lastTranscript: String? = nil
}

final class StateStore {
  private let file: URL
  private(set) var state: MeetingState
  init(directory: URL? = nil) throws {
    let base =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Meeting Notes", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    file = base.appendingPathComponent("state.json")
    state =
      FileManager.default.fileExists(atPath: file.path)
      ? try JSONDecoder().decode(MeetingState.self, from: Data(contentsOf: file)) : MeetingState()
  }
  func update(_ change: (inout MeetingState) -> Void) throws {
    var next = state
    change(&next)
    try JSONEncoder().encode(next).write(to: file, options: .atomic)
    state = next
  }
}

enum MeetingFiles {
  static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Documents/meeting-notes", isDirectory: true)
  static let audios = root.appendingPathComponent("audios", isDirectory: true)
  static let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
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
  static func audio(for stem: String) -> URL { audios.appendingPathComponent(stem + ".m4a") }
  static func transcript(for stem: String) -> URL {
    transcripts.appendingPathComponent(stem + ".txt")
  }
  static func capture(for stem: String) -> URL {
    audios.appendingPathComponent("." + stem + ".recording", isDirectory: true)
  }
}

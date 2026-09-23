import Foundation

struct MeetingError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct MeetingSession: Codable {
  let startedAt: Date
  let stem: String
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
    for date: Date, in audioDirectory: URL = audios, transcriptDirectory: URL = transcripts
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let base = formatter.string(from: date)
    var candidate = base
    var suffix = 2
    while ["m4a", "mp3"].contains(where: {
      FileManager.default.fileExists(
        atPath: audioDirectory.appendingPathComponent(candidate + "." + $0).path)
    })
      || FileManager.default.fileExists(
        atPath: transcriptDirectory.appendingPathComponent(candidate + ".txt").path)
      || FileManager.default.fileExists(
        atPath: audioDirectory.appendingPathComponent("." + candidate + ".recording").path)
    {
      candidate = "\(base)-\(suffix)"
      suffix += 1
    }
    return candidate
  }
  static func audio(for stem: String) -> URL { audios.appendingPathComponent(stem + ".m4a") }
  static func transcript(for stem: String) -> URL {
    transcripts.appendingPathComponent(stem + ".txt")
  }
  static func capture(for stem: String) -> URL {
    audios.appendingPathComponent("." + stem + ".recording", isDirectory: true)
  }
}

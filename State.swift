import Foundation

struct MeetingSession: Codable {
  let startedAt: Date
  let stem: String
  let launchedOBS: Bool
  var recordedPath: String?
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
    if FileManager.default.fileExists(atPath: file.path) {
      state = try JSONDecoder().decode(MeetingState.self, from: Data(contentsOf: file))
    } else {
      state = MeetingState()
    }
  }

  func update(_ change: (inout MeetingState) -> Void) throws {
    var next = state
    change(&next)
    let data = try JSONEncoder().encode(next)
    try data.write(to: file, options: .atomic)
    state = next
  }
}

enum MeetingFiles {
  static func waitForMP3(
    _ file: URL, attempts: Int = 40, interval: UInt64 = 250_000_000
  ) async throws {
    guard file.pathExtension.lowercased() == "mp3" else {
      throw MeetingError("OBS returned a non-MP3 path: \(file.lastPathComponent).")
    }
    var previousSize: Int64 = -1
    var detail = "File does not exist yet."
    for attempt in 0..<attempts {
      try Task.checkCancellation()
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        detail = "size=\(size) bytes"
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
          throw MeetingError("The recording path is not a regular file.")
        }
        if size > 0 && size == previousSize {
          AppLog.event("mp3.ready", "\(file.path); \(detail)")
          return
        }
        previousSize = size
      } catch {
        detail = error.localizedDescription
      }
      if attempt == 0 { AppLog.event("mp3.waiting", "\(file.path); \(detail)") }
      try await Task.sleep(nanoseconds: interval)
    }
    throw MeetingError(
      "MP3 not ready: \(file.lastPathComponent). \(detail) Retry Transcription when OBS finishes saving."
    )
  }

  static let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/meeting-notes", isDirectory: true)
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
    while FileManager.default.fileExists(
      atPath: audioDirectory.appendingPathComponent(candidate + ".mp3").path)
      || FileManager.default.fileExists(
        atPath: transcriptDirectory.appendingPathComponent(candidate + ".txt").path)
    {
      candidate = "\(base)-\(suffix)"
      suffix += 1
    }
    return candidate
  }

  static func audio(for stem: String) -> URL { audios.appendingPathComponent(stem + ".mp3") }
  static func transcript(for stem: String) -> URL {
    transcripts.appendingPathComponent(stem + ".txt")
  }
}

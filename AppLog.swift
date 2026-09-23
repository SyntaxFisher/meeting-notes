import Foundation

final class AppLog: @unchecked Sendable {
  static let shared = AppLog()
  private let lock = NSLock()
  private let directory: URL
  private let maxBytes: Int

  init(directory: URL? = nil, maxBytes: Int = 2_000_000) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Meeting Notes", isDirectory: true)
    self.maxBytes = maxBytes
  }

  static func event(_ name: String, _ detail: String = "") {
    shared.record(name, detail)
  }

  func record(_ name: String, _ detail: String = "") {
    lock.lock()
    defer { lock.unlock() }
    do {
      let manager = FileManager.default
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("meeting-notes.log")
      let size =
        (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
        .intValue ?? 0
      if size >= maxBytes {
        let previous = directory.appendingPathComponent("meeting-notes.previous.log")
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
        try manager.moveItem(at: file, to: previous)
      }
      if !manager.fileExists(atPath: file.path) {
        guard
          manager.createFile(
            atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MeetingError("Cannot create diagnostic log.") }
      }
      let entry = [
        "time": ISO8601DateFormatter().string(from: Date()),
        "event": name, "detail": detail,
      ]
      var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
      data.append(0x0A)
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      NSLog("Meeting Notes log failure: %@", error.localizedDescription)
    }
  }
}

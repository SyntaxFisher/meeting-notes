import Foundation

/// Keeps what recent meetings started from and what the app decided, so a meeting can be
/// replayed later against the same input: the capture tracks with their manifest, roster and
/// speaker timeline, the Teams trace around the recording, the helper's result without voice
/// embeddings, every segment's naming evidence, and the app, helper, Teams and macOS versions.
///
/// Correcting the transcript removes the archived transcription, so the archive keeps no
/// uncorrected copy of it.
///
/// The archive lives in the app's Caches folder, which macOS may clear. It exists only while
/// `keepAudio` is on; turning that off removes it, and nothing is archived until it is on again.
/// The oldest meetings are removed first once all archives exceed `budget`, except meetings
/// still recording, waiting or failed and the newest other archive, which may exceed the budget
/// alone.
enum ReconstructionArchive {
  static let budget: Int64 = 200_000_000

  /// What a meeting allows its archive to hold when the archive is written: everything, only
  /// the capture tracks once its transcript was corrected, or nothing once it was deleted, its
  /// audio removed or kept audio turned off.
  enum Allowance {
    case everything
    case captureOnly
    case nothing
  }

  /// Archive changes run one at a time, so a meeting's state checked when writing still holds
  /// when a correction, deletion or audio removal next touches the archive.
  private static let lock = NSLock()
  nonisolated(unsafe) private static var keepsAudio = true

  struct Transcription: Codable {
    var app: String
    var helper: TranscriptSegments?
    var naming: [SpeakerFusion.Decision]?
  }

  /// `~/Library/Caches/com.jona.meeting-notes`, or `MEETING_NOTES_CACHE_DIR` for isolated runs.
  static var cacheRoot: URL {
    if let directory = ProcessInfo.processInfo.environment["MEETING_NOTES_CACHE_DIR"] {
      return URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.jona.meeting-notes", isDirectory: true)
  }

  static var defaultDirectory: URL {
    cacheRoot.appendingPathComponent("reconstruction", isDirectory: true)
  }

  static func url(for id: String, in directory: URL = defaultDirectory) -> URL {
    directory.appendingPathComponent(id, isDirectory: true)
  }

  /// Saves the Teams trace of a recording that just ended, whatever its outcome.
  static func keepTrace(_ trace: Data, id: String, in directory: URL = defaultDirectory) throws {
    try keepTrace(id: id, in: directory) { try $0(trace) }
  }

  /// Saves the Teams trace `export` writes piece by piece, replacing an earlier one only once
  /// it is complete.
  static func keepTrace(
    id: String, in directory: URL = defaultDirectory,
    _ export: (_ write: (Data) throws -> Void) throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard keepsAudio else { return }
    let manager = FileManager.default
    let target = url(for: id, in: directory)
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    let partial = target.appendingPathComponent(".teams-trace-\(UUID().uuidString)")
    try Data().write(to: partial)
    do {
      let handle = try FileHandle(forWritingTo: partial)
      defer { try? handle.close() }
      try export { try handle.write(contentsOf: $0) }
      try handle.close()
      let file = target.appendingPathComponent("teams-trace.jsonl")
      if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
      try manager.moveItem(at: partial, to: file)
    } catch {
      try? manager.removeItem(at: partial)
      throw error
    }
  }

  /// Moves `capture` into the meeting's archive with the transcription that used it, replacing
  /// an earlier capture and transcription of the same meeting, as far as `allowance`, checked
  /// while no other archive change runs, permits; otherwise the capture is deleted.
  static func keep(
    capture: URL, id: String, result: TranscriptSegments?, naming: [SpeakerFusion.Decision]?,
    app: String = appVersion, in directory: URL = defaultDirectory,
    allowance: () -> Allowance = { .everything }
  ) throws {
    let manager = FileManager.default
    var helper = result
    helper?.voiceEmbeddings = nil
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let details = try encoder.encode(Transcription(app: app, helper: helper, naming: naming))
    lock.lock()
    defer { lock.unlock() }
    let allowed = keepsAudio ? allowance() : .nothing
    guard allowed != .nothing else {
      try manager.removeItem(at: capture)
      return
    }
    let target = url(for: id, in: directory)
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    let staging = target.appendingPathComponent(".capture-\(UUID().uuidString)", isDirectory: true)
    try manager.moveItem(at: capture, to: staging)
    let archived = target.appendingPathComponent("capture", isDirectory: true)
    if manager.fileExists(atPath: archived.path) { try manager.removeItem(at: archived) }
    try manager.moveItem(at: staging, to: archived)
    let file = target.appendingPathComponent("transcription.json")
    if allowed == .everything {
      try details.write(to: file, options: .atomic)
    } else if manager.fileExists(atPath: file.path) {
      try manager.removeItem(at: file)
    }
  }

  /// Removes every archive without kept audio; otherwise archives of meetings that no longer
  /// `exist` and the oldest above `budget`, sparing `protected` meetings and the newest other
  /// archive.
  @discardableResult
  static func enforce(
    keepAudio: Bool, protected: Set<String> = [], budget: Int64 = budget,
    exists: (String) -> Bool = { _ in true }, in directory: URL = defaultDirectory
  ) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    var entries = archives(in: directory)
    var removed: [String] = []
    func remove(_ entry: (id: String, url: URL, bytes: Int64)) -> Bool {
      do {
        try FileManager.default.removeItem(at: entry.url)
        removed.append(entry.id)
        return true
      } catch {
        AppLog.event("reconstruction.removeFailed", "\(entry.id): \(error.localizedDescription)")
        return false
      }
    }
    if keepAudio {
      entries.removeAll { !protected.contains($0.id) && !exists($0.id) && remove($0) }
    }
    var total = entries.reduce(0) { $0 + $1.bytes }
    let newest = keepAudio ? entries.last { !protected.contains($0.id) }?.id : nil
    for entry in entries
    where !keepAudio || (total > budget && !protected.contains(entry.id) && entry.id != newest) {
      if remove(entry) { total -= entry.bytes }
    }
    if !removed.isEmpty { AppLog.event("reconstruction.removed", removed.joined(separator: ",")) }
    return removed
  }

  /// Whether archives may be written: the app sets this whenever kept audio is turned on or
  /// off, before removing archives, so an archive written meanwhile is removed or not written.
  static func setKeepsAudio(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    keepsAudio = value
  }

  /// Removes the archived transcription once its transcript is corrected, so no uncorrected
  /// copy remains; the capture tracks stay for a replay.
  static func forgetTranscription(of id: String, in directory: URL = defaultDirectory) {
    lock.lock()
    defer { lock.unlock() }
    let file = url(for: id, in: directory).appendingPathComponent("transcription.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do {
      try FileManager.default.removeItem(at: file)
    } catch {
      AppLog.event("reconstruction.forgetFailed", "\(id): \(error.localizedDescription)")
    }
  }

  static func remove(_ ids: Set<String>, in directory: URL = defaultDirectory) throws {
    lock.lock()
    defer { lock.unlock() }
    for id in ids {
      let target = url(for: id, in: directory)
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
    }
  }

  static var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  /// Archived meetings, oldest first.
  private static func archives(in directory: URL) -> [(id: String, url: URL, bytes: Int64)] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    return entries.compactMap { url -> (id: String, url: URL, bytes: Int64)? in
      let id = url.lastPathComponent
      guard MeetingFiles.date(fromID: id) != nil else { return nil }
      return (id, url, size(of: url))
    }.sorted {
      let dates = (MeetingFiles.date(fromID: $0.id)!, MeetingFiles.date(fromID: $1.id)!)
      return dates.0 != dates.1
        ? dates.0 < dates.1 : $0.id.compare($1.id, options: .numeric) == .orderedAscending
    }
  }

  private static func size(of directory: URL) -> Int64 {
    let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    var total: Int64 = 0
    while let file = enumerator?.nextObject() as? URL {
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
  }
}

import Foundation

enum RecordingRetention {
  static let audioLimit: Int64 = 100_000_000
  static let transcriptLimit: Int64 = 10_000_000_000

  /// Deletes the oldest timestamped files in each folder until it fits its budget. The newest
  /// file of each folder and the protected stem are always kept, so a folder can exceed its budget.
  static func enforce(
    root: URL, protectedStem: String? = nil, audioBudget: Int64 = audioLimit,
    transcriptBudget: Int64 = transcriptLimit
  ) throws {
    try prune(
      root.appendingPathComponent("audios"), extensions: ["m4a", "mp3"], budget: audioBudget,
      protectedStem: protectedStem)
    try prune(
      root.appendingPathComponent("transcripts"), extensions: ["txt"], budget: transcriptBudget,
      protectedStem: protectedStem)
  }

  private static func prune(
    _ directory: URL, extensions: [String], budget: Int64, protectedStem: String?
  ) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directory.path) else { return }
    var files: [(stem: String, date: Date, url: URL, size: Int64)] = []
    for file in try manager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles])
    {
      let stem = file.deletingPathExtension().lastPathComponent
      guard extensions.contains(file.pathExtension.lowercased()),
        let date = MeetingFiles.date(fromStem: stem)
      else { continue }
      let attributes = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
      files.append((stem, date, file, Int64(attributes.fileSize ?? 0)))
    }
    files.sort {
      $0.date != $1.date
        ? $0.date < $1.date : $0.stem.compare($1.stem, options: .numeric) == .orderedAscending
    }
    let newest = files.last?.stem
    var total = files.reduce(0) { $0 + $1.size }
    for file in files {
      guard total > budget else { break }
      guard file.stem != protectedStem, file.stem != newest else { continue }
      try manager.removeItem(at: file.url)
      total -= file.size
      AppLog.event("retention.deleted", "\(file.url.path); bytes=\(file.size)")
    }
    AppLog.event(
      "retention.complete", "\(directory.lastPathComponent); bytes=\(total); budget=\(budget)")
  }
}

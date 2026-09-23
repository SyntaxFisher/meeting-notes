import Foundation

enum RecordingRetention {
  static let limit: Int64 = 1_000_000_000

  static func enforce(root: URL, protectedStem: String? = nil, budget: Int64 = limit) throws {
    let manager = FileManager.default
    var groups: [String: [(URL, Int64)]] = [:]
    var total: Int64 = 0
    for (folder, extensions) in [("audios", ["m4a", "mp3"]), ("transcripts", ["txt"])] {
      let directory = root.appendingPathComponent(folder)
      guard manager.fileExists(atPath: directory.path) else { continue }
      for file in try manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
      {
        let stem = file.deletingPathExtension().lastPathComponent
        guard extensions.contains(file.pathExtension.lowercased()),
          stem.range(of: #"^\d{8}T\d{6}Z(?:-\d+)?$"#, options: .regularExpression) != nil
        else { continue }
        let attributes = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
        let size = Int64(attributes.fileSize ?? 0)
        groups[stem, default: []].append((file, size))
        total += size
      }
    }
    for stem in groups.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
      guard total > budget else { break }
      guard stem != protectedStem else { continue }
      for (file, size) in groups[stem]! {
        try manager.removeItem(at: file)
        total -= size
        AppLog.event("retention.deleted", "\(file.path); bytes=\(size)")
      }
    }
    AppLog.event("retention.complete", "bytes=\(total); budget=\(budget)")
  }
}

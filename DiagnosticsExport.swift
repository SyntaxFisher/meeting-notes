import Foundation

/// Packs everything Meeting Notes knows about one meeting into a zip file for debugging:
///
/// - `<id>/capture/`, `teams-trace.jsonl`, `transcription.json`: the reconstruction archive, so
///   `MeetingNotes replay <unzipped>/<id> <output>` runs on the folder as it is. Without an
///   archived trace, the Teams trace around the recording is taken from the live trace.
/// - `<id>/meeting/`: every file of the meeting in the meetings folder, such as the audio,
///   transcript, record and summary, and an unfinished capture as `meeting/unfinished-capture/`.
///   A mixed recording is left out when its capture tracks are included, since replay mixes
///   them again.
/// - `<id>/logs/`: the diagnostic log around the meeting and the meeting's lifecycle events.
/// - `<id>/config.json` and `<id>/manifest.json` with versions, the included files, what was
///   missing and what was left out, and why.
///
/// Without `includesAudio`, every audio file is left out, so the zip stays small enough to
/// attach; replay then only replays the Teams trace.
///
/// With `splitsIntoParts`, a zip larger than `partSize` is written as `<name>.zip.001`,
/// `<name>.zip.002`, ... instead, which `cat <name>.zip.* > <name>.zip` joins again.
///
/// The library and the archive are only read.
struct DiagnosticsExport {
  var library: MeetingLibrary
  var archives = ReconstructionArchive.defaultDirectory
  var trace = TeamsTrace.shared
  var logs = AutomationPaths.standard.logDirectory
  var config = AutomationPaths.standard.configFile
  var app = ReconstructionArchive.appVersion
  var includesAudio = true
  var splitsIntoParts = false
  /// Below the 50 MB upload limit of chat attachments, whether counted in MB or MiB.
  var partSize = 49_000_000
  /// How much of the diagnostic log before and after the meeting is included.
  static let logMargin: TimeInterval = 600

  struct Manifest: Codable, Equatable {
    var id: String
    var title: String?
    var status: MeetingStatus
    var exportedAt: Date
    var app: String
    var macOS: String
    var teams: String?
    var locale: String
    var files: [String: Int64]
    var missing: [String]
    var omitted: [String]

    enum CodingKeys: String, CodingKey {
      case id, title, status, app, teams, locale, files, missing, omitted
      case exportedAt = "exported_at"
      case macOS = "macos"
    }
  }

  /// `meeting-notes-<id>-diagnostics.zip`
  static func fileName(for id: String) -> String { "meeting-notes-\(id)-diagnostics.zip" }

  /// The parts of a split zip at `destination`, in order.
  static func parts(of destination: URL) -> [URL] {
    let directory = destination.deletingLastPathComponent()
    let prefix = destination.lastPathComponent + "."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter {
      $0.hasPrefix(prefix) && $0.count == prefix.count + 3
        && $0.dropFirst(prefix.count).allSatisfy { ("0"..."9").contains($0) }
    }.sorted().map { directory.appendingPathComponent($0) }
  }

  /// Writes the zip, or its parts, to `destination`. Existing files, including the parts of an
  /// earlier split export, are replaced only when `replacing`.
  @discardableResult
  func write(_ id: String, to destination: URL, replacing: Bool = false) throws -> Manifest {
    let manager = FileManager.default
    var existing = Self.parts(of: destination)
    if manager.fileExists(atPath: destination.path) { existing.append(destination) }
    if !replacing, let first = existing.first {
      throw MeetingError("\(first.path) already exists.")
    }
    let record = try library.load(id)
    let staging = manager.temporaryDirectory.appendingPathComponent(
      "meeting-notes-diagnostics-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: staging) }
    let folder = staging.appendingPathComponent(id, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)

    var missing: [String] = []
    if ReconstructionArchive.copy(id, to: folder, in: archives) {
      if !manager.fileExists(atPath: folder.appendingPathComponent("capture").path) {
        missing.append("Capture tracks: not archived.")
      }
      if !manager.fileExists(atPath: folder.appendingPathComponent("transcription.json").path) {
        missing.append(
          "Transcription result: not archived. Correcting the transcript removes it, and it is "
            + "written only after a successful transcription.")
      }
    } else {
      missing.append(
        "Reconstruction archive: none for this meeting. It exists only while audio is kept, "
          + "for recent meetings, and macOS may clear it.")
    }
    let traceFile = folder.appendingPathComponent("teams-trace.jsonl")
    if !manager.fileExists(atPath: traceFile.path) {
      let end = record.endedAt ?? record.failedAt ?? record.updatedAt ?? Date()
      let data = trace.export(from: record.startedAt - TeamsTrace.preRoll, to: end)
      if data.isEmpty {
        missing.append("Teams trace: none around this meeting.")
      } else {
        try data.write(to: traceFile)
      }
    }

    let meeting = folder.appendingPathComponent("meeting", isDirectory: true)
    try manager.createDirectory(at: meeting, withIntermediateDirectories: true)
    try library.copyFiles(of: id, to: meeting)
    if library.audioURL(of: record) == nil { missing.append("Audio: no saved audio file.") }
    if library.transcriptURL(of: record) == nil { missing.append("Transcript: none saved.") }

    let logFolder = folder.appendingPathComponent("logs", isDirectory: true)
    let events = lifecycleEvents(of: id)
    let lastEvent = Self.times(in: events).max()
    let until =
      record.status.isInProgress
      ? Date()
      : [record.endedAt, record.failedAt, lastEvent].compactMap { $0 }.max() ?? record.startedAt
    let log = diagnosticLog(from: record.startedAt - Self.logMargin, to: until + Self.logMargin)
    if log.isEmpty {
      missing.append("Diagnostic log: no entries around this meeting.")
    } else {
      try manager.createDirectory(at: logFolder, withIntermediateDirectories: true)
      try log.write(to: logFolder.appendingPathComponent("meeting-notes.log"))
    }
    if events.isEmpty {
      missing.append("Lifecycle events: none logged for this meeting.")
    } else {
      try manager.createDirectory(at: logFolder, withIntermediateDirectories: true)
      try events.write(to: logFolder.appendingPathComponent("events.jsonl"))
    }
    if manager.fileExists(atPath: config.path) {
      try manager.copyItem(at: config, to: folder.appendingPathComponent("config.json"))
    }
    let omitted = try leaveOutAudio(in: folder, mixed: library.audioURL(of: record))

    var manifest = Manifest(
      id: id, title: record.title, status: record.status, exportedAt: Date(), app: app,
      macOS: ProcessInfo.processInfo.operatingSystemVersionString, teams: TeamsTrace.teamsVersion,
      locale: Locale.current.identifier, files: [:], missing: missing, omitted: omitted)
    manifest.files = Self.sizes(in: folder)
    try JSONCoding.encoder(pretty: true).encode(manifest)
      .write(to: folder.appendingPathComponent("manifest.json"))

    let zip = staging.appendingPathComponent("export.zip")
    try Self.zip(folder, to: zip)
    let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    if splitsIntoParts, size > partSize {
      let parts = staging.appendingPathComponent("parts", isDirectory: true)
      try Self.split(zip, into: parts, named: destination.lastPathComponent, size: partSize)
      for file in existing { try manager.removeItem(at: file) }
      for part in try manager.contentsOfDirectory(atPath: parts.path).sorted() {
        try manager.moveItem(
          at: parts.appendingPathComponent(part),
          to: destination.deletingLastPathComponent().appendingPathComponent(part))
      }
    } else {
      for file in existing where file != destination { try manager.removeItem(at: file) }
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: zip)
      } else {
        try manager.moveItem(at: zip, to: destination)
      }
    }
    AppLog.event("diagnostics.exported", "\(id) \(destination.lastPathComponent)")
    return manifest
  }

  static let audioExtensions: Set<String> = ["aac", "m4a", "mp3", "wav", "caf"]

  /// Removes the audio the export leaves out from the staged `folder` and says what it left out:
  /// with `includesAudio`, the mixed recordings whose capture tracks are included, otherwise
  /// every audio file.
  private func leaveOutAudio(in folder: URL, mixed: URL?) throws -> [String] {
    let manager = FileManager.default
    guard includesAudio else {
      let audio = Self.sizes(in: folder).keys.filter {
        Self.audioExtensions.contains(($0 as NSString).pathExtension.lowercased())
      }.sorted()
      for path in audio { try manager.removeItem(at: folder.appendingPathComponent(path)) }
      return audio.isEmpty ? [] : ["Audio: left out on export (\(audio.joined(separator: ", ")))."]
    }
    var omitted: [String] = []
    for (mix, tracks) in [
      (mixed.map { "meeting/" + $0.lastPathComponent }, "capture"),
      ("meeting/unfinished-capture/mixed.m4a", "meeting/unfinished-capture"),
    ] {
      guard let mix, manager.fileExists(atPath: folder.appendingPathComponent(mix).path),
        CaptureTrack.hasTracks(in: folder.appendingPathComponent(tracks, isDirectory: true))
      else { continue }
      try manager.removeItem(at: folder.appendingPathComponent(mix))
      omitted.append("Mixed recording \(mix): replay mixes it from the tracks in \(tracks)/.")
    }
    return omitted
  }

  /// The `time` of each JSON line, with or without fractional seconds.
  private static func times(in lines: Data) -> [Date] {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return lines.split(separator: UInt8(ascii: "\n")).compactMap { line in
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let time = object["time"] as? String
      else { return nil }
      return fractional.date(from: time) ?? plain.date(from: time)
    }
  }

  /// Diagnostic log lines, oldest file first, whose time lies between `start` and `end`.
  private func diagnosticLog(from start: Date, to end: Date) -> Data {
    lines(in: ["meeting-notes.previous.log", "meeting-notes.log"]) { line in
      guard let time = Self.times(in: line).first else { return false }
      return time >= start && time <= end
    }
  }

  private func lifecycleEvents(of id: String) -> Data {
    lines(in: ["events.previous.jsonl", "events.jsonl"]) { line in
      (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["meeting"] as? String
        == id
    }
  }

  private func lines(in files: [String], where include: (Data) -> Bool) -> Data {
    var output = Data()
    for name in files {
      guard let data = try? Data(contentsOf: logs.appendingPathComponent(name)) else { continue }
      for line in data.split(separator: UInt8(ascii: "\n")) where include(Data(line)) {
        output.append(contentsOf: line)
        output.append(UInt8(ascii: "\n"))
      }
    }
    return output
  }

  /// Every regular file below `folder` with its size, by path relative to `folder`.
  private static func sizes(in folder: URL) -> [String: Int64] {
    let base = folder.standardizedFileURL.path + "/"
    var sizes: [String: Int64] = [:]
    let enumerator = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    while let file = enumerator?.nextObject() as? URL {
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      let path = file.standardizedFileURL.path
      sizes[path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path] = Int64(
        values?.fileSize ?? 0)
    }
    return sizes
  }

  /// Splits `file` into `<name>.001`, `<name>.002`, ... of at most `size` bytes in `folder`.
  private static func split(_ file: URL, into folder: URL, named name: String, size: Int) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var index = 1
    while let chunk = try input.read(upToCount: size), !chunk.isEmpty {
      try chunk.write(to: folder.appendingPathComponent(String(format: "%@.%03d", name, index)))
      index += 1
    }
  }

  private static func zip(_ folder: URL, to zip: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = [
      "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", folder.path,
      zip.path,
    ]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MeetingError(
        "Could not create the zip file: "
          + String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}

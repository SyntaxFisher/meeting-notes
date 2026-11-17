import Foundation

enum DiagnosticsExportSmoke {
  static func run(_ root: URL) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: root)
    let library = MeetingLibrary(root: root.appendingPathComponent("meetings"))
    let archives = root.appendingPathComponent("reconstruction")
    let logs = root.appendingPathComponent("logs")
    let config = root.appendingPathComponent("config.json")
    for directory in [library.audios, library.transcripts, logs] {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let id = "20261110T090000Z"
    let other = "20261110T100000Z"
    let start = MeetingFiles.date(fromID: id)!
    var record = MeetingRecord(id: id, title: "Weekly", startedAt: start, status: .complete)
    record.endedAt = start + 1800
    try library.save(record)
    try library.save(MeetingRecord(id: other, startedAt: start + 3600, status: .complete))
    try Data("audio".utf8).write(to: MeetingFiles.audio(for: id, in: library.audios))
    try Data("[00:00] Anna: Hi".utf8).write(
      to: MeetingFiles.transcript(for: id, in: library.transcripts))
    try Data("Summary".utf8).write(
      to: library.transcripts.appendingPathComponent("\(id).summary.md"))
    try Data("other".utf8).write(to: MeetingFiles.audio(for: other, in: library.audios))

    let capture = root.appendingPathComponent("capture")
    try manager.createDirectory(at: capture, withIntermediateDirectories: true)
    try Data("track".utf8).write(to: capture.appendingPathComponent("system.aac"))
    try ReconstructionArchive.keepTrace(Data("{\"k\":\"session\"}\n".utf8), id: id, in: archives)
    try ReconstructionArchive.keep(
      capture: capture, id: id, result: nil, naming: nil, app: "fixture", in: archives)
    ReconstructionArchive.forgetTranscription(of: id, in: archives)

    let formatter = ISO8601DateFormatter()
    func logLine(_ date: Date, _ event: String) -> String {
      "{\"detail\":\"\",\"event\":\"\(event)\",\"time\":\"\(formatter.string(from: date))\"}\n"
    }
    try Data(
      (logLine(start - 7200, "log.before") + logLine(start + 60, "log.during")
        + logLine(start + 2600, "log.transcribed")
        + logLine(start + 7200, "log.after")).utf8
    ).write(to: logs.appendingPathComponent("meeting-notes.log"))
    try Data(
      ("{\"event\":\"transcript.ready\",\"meeting\":\"\(id)\",\"time\":\""
        + AutomationFormat.timestamp(start + 2400) + "\"}\n"
        + "{\"event\":\"recording.started\",\"meeting\":\"\(other)\"}\n").utf8
    ).write(to: logs.appendingPathComponent("events.jsonl"))
    try Data("{\"keepAudio\":true}".utf8).write(to: config)

    let export = DiagnosticsExport(
      library: library, archives: archives,
      trace: TeamsTrace(directory: root.appendingPathComponent("trace")), logs: logs,
      config: config, app: "fixture")
    let zip = root.appendingPathComponent(DiagnosticsExport.fileName(for: id))
    let manifest = try export.write(id, to: zip)
    precondition(
      manifest.app == "fixture" && manifest.status == .complete
        && manifest.missing.count == 1 && manifest.missing[0].hasPrefix("Transcription result"),
      "The manifest lists what was not available: \(manifest.missing)")

    let unpacked = root.appendingPathComponent("unpacked")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
    try ditto.run()
    ditto.waitUntilExit()
    precondition(ditto.terminationStatus == 0)
    let folder = unpacked.appendingPathComponent(id)
    func text(_ path: String) -> String? {
      try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }
    precondition(
      text("capture/system.aac") == "track" && text("teams-trace.jsonl") != nil
        && text("meeting/\(id).m4a") == nil && text("meeting/\(id).summary.md") == "Summary"
        && text("meeting/\(id).json") != nil && text("config.json") != nil
        && text("manifest.json") != nil
        && !manager.fileExists(atPath: folder.appendingPathComponent("meeting/\(other).m4a").path),
      "The zip holds the meeting's archive, files and settings in a replayable folder")
    let log = text("logs/meeting-notes.log") ?? ""
    let events = text("logs/events.jsonl") ?? ""
    precondition(
      log.contains("log.during") && log.contains("log.transcribed") && !log.contains("log.before")
        && !log.contains("log.after")
        && events.contains(id) && !events.contains(other),
      "Logs are limited to the meeting")
    precondition(
      manifest.files["capture/system.aac"] == 5 && manifest.files["meeting/\(id).m4a"] == nil
        && manifest.omitted.count == 1 && manifest.omitted[0].hasPrefix("Mixed recording"),
      "The manifest lists file sizes and leaves out the mix its capture tracks replace")

    var silent = export
    silent.includesAudio = false
    let small = try silent.write(id, to: root.appendingPathComponent("no-audio.zip"))
    precondition(
      small.files.keys.allSatisfy {
        !DiagnosticsExport.audioExtensions.contains(($0 as NSString).pathExtension)
      }
        && small.files["meeting/\(id).summary.md"] != nil && small.files["teams-trace.jsonl"] != nil
        && small.omitted.count == 1 && small.omitted[0].hasPrefix("Audio"),
      "Without audio, the zip holds everything but the audio: \(small.files.keys.sorted())")

    do {
      try export.write(id, to: zip)
      preconditionFailure("An existing zip must not be overwritten")
    } catch {}
    try export.write(id, to: zip, replacing: true)

    let failed = "20261110T110000Z"
    try library.save(
      MeetingRecord(
        id: failed, startedAt: MeetingFiles.date(fromID: failed)!, status: .interrupted))
    let unfinished = MeetingFiles.capture(for: failed, in: library.audios)
    try manager.createDirectory(at: unfinished, withIntermediateDirectories: true)
    try Data("mic".utf8).write(to: unfinished.appendingPathComponent("microphone.aac"))
    try Data("mix".utf8).write(to: unfinished.appendingPathComponent("mixed.m4a"))
    let interrupted = try export.write(
      failed, to: root.appendingPathComponent(DiagnosticsExport.fileName(for: failed)))
    precondition(
      interrupted.files["meeting/unfinished-capture/microphone.aac"] == 3
        && interrupted.missing.contains { $0.hasPrefix("Reconstruction archive") }
        && interrupted.files["meeting/unfinished-capture/mixed.m4a"] == nil
        && interrupted.missing.contains { $0.hasPrefix("Audio") },
      "An interrupted meeting exports its unfinished capture and says what is missing")
    print("Diagnostics export: meeting files, archive, logs and manifest in one zip: OK")
  }
}

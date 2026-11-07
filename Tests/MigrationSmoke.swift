import Foundation

/// Meetings saved by 1.x and 2.0 under `yyyy-MM-dd HH.mm[-N][ Title]` names become
/// `<UTC id>.<extension>` files with a record each.
enum MigrationSmoke {
  static let berlin = TimeZone(identifier: "Europe/Berlin")!

  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mn-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try testMigration(root.appendingPathComponent("full"))
    try testResume(root.appendingPathComponent("resume"))
    print("File migration: 1.x and 2.0 names, records, extras, collisions and resume: OK")
  }

  private static func testMigration(_ root: URL) throws {
    let manager = FileManager.default
    let library = MeetingLibrary(root: root)
    library.timeZone = berlin
    let transcripts = library.transcripts
    let audios = library.audios
    for folder in [transcripts, audios] {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func write(_ folder: URL, _ name: String, _ text: String = "data") throws {
      try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func exists(_ folder: URL, _ name: String) -> Bool {
      manager.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    // 1.x: a transcript with its audio and a summary, all titled.
    try write(
      transcripts, "2026-11-03 17.39 Weekly Sync- v1.2.txt",
      "Weekly Sync\n\n[00:00:20] Speaker 1: Hello.\n\n[00:01:05] Speaker 2: Bye.\n")
    try write(transcripts, "2026-11-03 17.39 Weekly Sync- v1.2.summary.md")
    try write(audios, "2026-11-03 17.39 Weekly Sync- v1.2.m4a")
    // 1.x: two recordings in the same minute, an untranscribed one and an interrupted one.
    try write(audios, "2026-11-04 09.00 Orphan.mp3")
    try manager.createDirectory(
      at: audios.appendingPathComponent(".2026-11-04 09.00-2.recording"),
      withIntermediateDirectories: true)
    try write(audios.appendingPathComponent(".2026-11-04 09.00-2.recording"), "system.aac")

    // 2.0: a record, files named with the title it had when saved, extras and a stray record.
    var record = MeetingRecord(
      id: "2026-11-05 15.28", title: "Retitled",
      startedAt: Date(timeIntervalSince1970: 1_793_888_887),
      status: .complete, source: .teams)
    record.audioFile = "2026-11-05 15.28 Weekly Sync.m4a"
    record.transcriptFile = "2026-11-05 15.28 Weekly Sync.txt"
    record.segments = [MeetingSegment(start: 0, end: 1, speaker: "Speaker 1", text: "Hi")]
    try JSONCoding.encoder(pretty: true).encode(record).write(
      to: transcripts.appendingPathComponent("2026-11-05 15.28.json"))
    try write(transcripts, "2026-11-05 15.28 Weekly Sync.txt", "[00:00:00] Speaker 1: Hi\n")
    try write(transcripts, "2026-11-05 15.28 A.txt", "an older copy")
    try write(transcripts, "2026-11-05 15.28 Weekly Sync.speakers.json", "{}")
    try write(transcripts, "2026-11-05 15.28 Weekly Sync.json", "{}")
    try write(audios, "2026-11-05 15.28 Weekly Sync.m4a")
    let locks = transcripts.appendingPathComponent(".edit-locks", isDirectory: true)
    try manager.createDirectory(at: locks, withIntermediateDirectories: true)
    try write(locks, "2026-11-05 15.28.lock", "")

    // Current files and unrelated files stay as they are.
    var current = MeetingRecord(
      id: "20261106T080000Z", startedAt: Date(timeIntervalSince1970: 1_794_038_400),
      status: .failed)
    current.error = "Kept"
    try library.save(current)
    try write(transcripts, "notes.txt")

    let result = try MeetingFilesMigration.run(root: root, timeZone: berlin)
    precondition(
      result.migrated == [
        "2026-11-03 17.39": "20261103T163900Z", "2026-11-04 09.00": "20261104T080000Z",
        "2026-11-04 09.00-2": "20261104T080000Z-2", "2026-11-05 15.28": "20261105T142807Z",
      ], "\(result.migrated)")
    precondition(result.skipped.isEmpty, "\(result.skipped)")

    let transcriptNames = Set(try manager.contentsOfDirectory(atPath: transcripts.path))
    precondition(
      transcriptNames == [
        ".edit-locks", "notes.txt",
        "20261103T163900Z.json", "20261103T163900Z.txt", "20261103T163900Z.summary.md",
        "20261104T080000Z.json", "20261104T080000Z-2.json",
        "20261105T142807Z.json", "20261105T142807Z.txt", "20261105T142807Z.legacy.txt",
        "20261105T142807Z.speakers.json", "20261105T142807Z.legacy.json",
        "20261106T080000Z.json",
      ])
    let audioNames = Set(try manager.contentsOfDirectory(atPath: audios.path))
    precondition(
      audioNames == [
        "20261103T163900Z.m4a", "20261104T080000Z.mp3", ".20261104T080000Z-2.recording",
        "20261105T142807Z.m4a",
      ])
    precondition(exists(audios, ".20261104T080000Z-2.recording/system.aac"))
    precondition(!exists(locks, "2026-11-05 15.28.lock") && !exists(locks, "migration-plan.json"))

    let meetings = Dictionary(uniqueKeysWithValues: library.meetings().map { ($0.id, $0) })
    precondition(meetings.count == 5)
    let weekly = meetings["20261103T163900Z"]!
    precondition(weekly.status == .complete && weekly.title == "Weekly Sync- v1.2")
    precondition(weekly.titleSource == .user)
    precondition(weekly.transcriptFile == "20261103T163900Z.txt")
    precondition(weekly.audioFile == "20261103T163900Z.m4a")
    precondition(weekly.segments.map(\.start) == [20, 65])
    precondition(weekly.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
    var local = DateComponents()
    (local.year, local.month, local.day, local.hour, local.minute) = (2026, 11, 3, 17, 39)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    precondition(weekly.startedAt == calendar.date(from: local))
    let orphan = meetings["20261104T080000Z"]!
    precondition(orphan.status == .untranscribed && orphan.title == "Orphan")
    precondition(orphan.audioFile == "20261104T080000Z.mp3")
    precondition(library.work(for: orphan).canRetry)
    let interrupted = meetings["20261104T080000Z-2"]!
    precondition(interrupted.status == .interrupted && interrupted.title == nil)
    precondition(library.work(for: interrupted).capture != nil)
    let retitled = meetings["20261105T142807Z"]!
    precondition(retitled.title == "Retitled" && retitled.segments == record.segments)
    precondition(retitled.startedAt == record.startedAt)
    precondition(retitled.source == .teams)
    precondition(retitled.transcriptFile == "20261105T142807Z.txt")
    precondition(retitled.audioFile == "20261105T142807Z.m4a")
    let transcript = try String(contentsOf: library.transcriptURL(of: retitled)!, encoding: .utf8)
    precondition(transcript == "[00:00:00] Speaker 1: Hi\n")
    let olderCopy = try String(
      contentsOf: transcripts.appendingPathComponent("20261105T142807Z.legacy.txt"),
      encoding: .utf8)
    precondition(olderCopy == "an older copy")
    precondition(meetings["20261106T080000Z"]?.error == "Kept")

    let again = try MeetingFilesMigration.run(root: root, timeZone: berlin)
    precondition(again == .init(), "A finished migration has nothing left to do")
  }

  /// A migration interrupted after its plan was saved continues with the planned ids and the
  /// titles the plan kept.
  private static func testResume(_ root: URL) throws {
    let manager = FileManager.default
    let library = MeetingLibrary(root: root)
    let locks = library.transcripts.appendingPathComponent(".edit-locks", isDirectory: true)
    try manager.createDirectory(at: locks, withIntermediateDirectories: true)
    try manager.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try #"{"2026-11-04 09.00":{"id":"20261104T080000Z","title":"Resumed"}}"#.write(
      to: locks.appendingPathComponent("migration-plan.json"), atomically: true, encoding: .utf8)
    try "[00:00:01] Speaker 1: Moved already\n".write(
      to: library.transcripts.appendingPathComponent("20261104T080000Z.txt"), atomically: true,
      encoding: .utf8)
    try "notes".write(
      to: library.transcripts.appendingPathComponent("2026-11-04 09.00 Resumed.summary.md"),
      atomically: true, encoding: .utf8)

    let result = try MeetingFilesMigration.run(root: root, timeZone: berlin)
    precondition(result.migrated == ["2026-11-04 09.00": "20261104T080000Z"])
    let resumed = try library.load("20261104T080000Z")
    precondition(resumed.status == .complete && resumed.title == "Resumed")
    precondition(resumed.segments.map(\.text) == ["Moved already"])
    precondition(
      manager.fileExists(
        atPath: library.transcripts.appendingPathComponent("20261104T080000Z.summary.md").path))
    precondition(
      !manager.fileExists(atPath: locks.appendingPathComponent("migration-plan.json").path))
  }
}

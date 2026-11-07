import Foundation

enum MeetingTitlesSmoke {
  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mn-titles-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try testInference()
    try testEligibility()
    try testProtectedTitles(root)
    try testNaming(root)
    print(
      "Meeting titles: provenance, untitled-only agent naming, protected existing titles and user edits: OK"
    )
  }

  private static func check(_ value: @autoclosure () throws -> Bool) throws {
    let passed = try value()
    precondition(passed)
  }

  private static func record(_ title: String?, source: MeetingTitleSource = .teams) -> MeetingRecord
  {
    var record = MeetingRecord(
      id: "20261106T090000Z", title: title, startedAt: Date(timeIntervalSince1970: 1_794_000_000),
      status: .complete, source: .teams, titleSource: source)
    record.segments = [
      .init(start: 0, end: 10, speaker: "Speaker 1", text: "Wir besprechen den Release-Plan.")
    ]
    record.speakers = [.init(label: "Speaker 1", name: "Max Mustermann")]
    return record
  }

  private static func testInference() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    func withoutProvenance(_ record: MeetingRecord) throws -> MeetingRecord {
      var json = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
      json.removeValue(forKey: "title_source")
      return try decoder.decode(
        MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
    try check(try withoutProvenance(record(nil)).titleSource == .none)
    try check(try withoutProvenance(record("Weekly")).titleSource == .teams)
    var manual = record("Mein Titel", source: .user)
    manual.source = .deviceAudio
    try check(try withoutProvenance(manual).titleSource == .user)
    for source in [MeetingTitleSource.none, .teams, .agent, .user] {
      let original = record(source == .none ? nil : "Weekly", source: source)
      try check(
        try decoder.decode(MeetingRecord.self, from: encoder.encode(original)).titleSource == source
      )
    }
  }

  private static func testEligibility() throws {
    for source in [MeetingTitleSource.none, .teams, .agent, .user] {
      precondition(record(nil, source: source).needsAgentTitle)
      precondition(record("  ", source: source).needsAgentTitle)
      for title in ["Max Mustermann", "Weekly", "Daily", "Mittagspause", "Release Planning"] {
        precondition(!record(title, source: source).needsAgentTitle, title)
      }
    }
    for proposed: String? in [nil, "", "  "] {
      do {
        try record(nil, source: .none).validateAgentTitle(proposed)
        preconditionFailure("An agent title must not be empty")
      } catch is MeetingError {}
    }
  }

  private static func testProtectedTitles(_ root: URL) throws {
    let library = MeetingLibrary(root: root)
    try FileManager.default.createDirectory(
      at: library.transcripts, withIntermediateDirectories: true)
    for (index, source) in [MeetingTitleSource.none, .teams, .agent, .user].enumerated() {
      var existing = record("Mittagspause", source: source)
      existing.id = "20261106T100\(index)00Z"
      existing.transcriptFile = existing.id + ".txt"
      let transcript = library.transcripts.appendingPathComponent(existing.transcriptFile!)
      let original = Data(MeetingLibrary.transcriptText(existing).utf8)
      try original.write(to: transcript)
      try library.save(existing)
      let before = try Data(contentsOf: library.recordURL(for: existing.id))
      do {
        _ = try library.updateMeeting(
          existing.id, title: .some("Mittagspause: Kurzer Test der Aufnahme"),
          names: ["Speaker 1": "Other"], expectedRevision: 0, titleSource: .agent)
        preconditionFailure("Every existing title must be protected atomically")
      } catch let error as MeetingError {
        precondition(error.message.contains("already has a title"))
      }
      try check(try Data(contentsOf: library.recordURL(for: existing.id)) == before)
      try check(try Data(contentsOf: transcript) == original)
    }
  }

  private static func testNaming(_ root: URL) throws {
    let library = MeetingLibrary(root: root)
    var baseline = record(nil, source: .none)
    baseline.transcriptFile = baseline.id + ".txt"
    let transcript = library.transcripts.appendingPathComponent(baseline.transcriptFile!)
    try Data(MeetingLibrary.transcriptText(baseline).utf8).write(to: transcript)
    try library.save(baseline)
    let named = try library.updateMeeting(
      baseline.id, title: .some("Abstimmung zum Release-Plan"), expectedRevision: 0,
      titleSource: .agent)
    precondition(named.record.titleSource == .agent && !named.record.needsAgentTitle)
    do {
      _ = try library.updateMeeting(
        baseline.id, title: .some("Another agent title"), expectedRevision: 1, titleSource: .agent)
      preconditionFailure("An agent must not rename its existing title")
    } catch is MeetingError {}
    let user = try library.updateMeeting(
      baseline.id, title: .some("Mein Release-Plan"), expectedRevision: 1)
    precondition(user.changed && user.record.titleSource == .user)
    precondition(user.record.title == "Mein Release-Plan")
    let untitled = try library.updateMeeting(baseline.id, title: .some(nil), expectedRevision: 2)
    precondition(untitled.record.titleSource == .none && untitled.record.needsAgentTitle)
    let renamed = try library.updateMeeting(
      baseline.id, title: .some("Abstimmung zum Release-Plan"), expectedRevision: 3,
      titleSource: .agent)
    precondition(renamed.record.titleSource == .agent)
    try check(
      try String(contentsOf: transcript, encoding: .utf8)
        == MeetingLibrary.transcriptText(renamed.record))
  }
}

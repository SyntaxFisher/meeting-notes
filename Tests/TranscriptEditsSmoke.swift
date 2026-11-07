import Foundation

enum TranscriptEditsSmoke {
  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mn-edits-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try testCorrections(root.appendingPathComponent("corrections"))
    try testMerge(root.appendingPathComponent("merge"))
    try testConcurrentWriters(root.appendingPathComponent("concurrent"))
    try testWriterProcesses(root.appendingPathComponent("processes"))
    try testPersistenceFailure(root.appendingPathComponent("failure"))
    print(
      "Transcript edits: atomic corrections, direct transcript replacement, speaker merges and concurrent writers: OK"
    )
  }

  static let meetingID = "2026-11-06 09.00"

  static func writeFixture(root: URL, text: String) throws {
    do {
      _ = try MeetingLibrary(root: root).editTranscript(
        meetingID, changes: [.init(segmentID: "s1", text: text)], expectedRevision: 0)
    } catch {
      FileHandle.standardError.write(Data(error.localizedDescription.utf8))
      exit(3)
    }
  }

  static func fixture(_ root: URL) throws -> (MeetingLibrary, MeetingRecord) {
    let library = MeetingLibrary(root: root)
    try FileManager.default.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: library.transcripts, withIntermediateDirectories: true)
    var record = MeetingRecord(
      id: meetingID, title: "Project review", startedAt: Date(timeIntervalSince1970: 1_794_000_000),
      status: .complete, source: .teams, trigger: .manual)
    record.durationSeconds = 24
    record.segments = [
      .init(start: 0, end: 5, speaker: "Jona", text: "The budget is 15,000 euros."),
      .init(start: 5, end: 10, speaker: "Speaker 1", text: "We use Cooper Netties."),
      .init(start: 5, end: 12, speaker: "Speaker 2", text: "I will prepare the launch."),
      .init(start: 12, end: 24, speaker: "Speaker 3", text: "Please check the budget."),
    ]
    record.speakers = [
      .init(
        label: "Jona", isLocalUser: true, identity: .localUser, source: .microphone,
        participant: "Jona Bihl", turns: 1, seconds: 5),
      .init(label: "Speaker 1", name: "Lena", source: .teams, turns: 1, seconds: 5),
      .init(label: "Speaker 2", source: .teams, turns: 1, seconds: 7),
      .init(label: "Speaker 3", name: "Alex", source: .teams, turns: 1, seconds: 12),
    ]
    record.audioFile = meetingID + ".m4a"
    record.transcriptFile = meetingID + ".txt"
    try Data([1, 2, 3, 4]).write(to: library.audios.appendingPathComponent(record.audioFile!))
    try MeetingLibrary.transcriptText(record).write(
      to: library.transcripts.appendingPathComponent(record.transcriptFile!), atomically: true,
      encoding: .utf8)
    try library.save(record)
    return (library, record)
  }

  static func testCorrections(_ root: URL) throws {
    let (library, baseline) = try fixture(root)
    let audio = try Data(contentsOf: library.audioURL(of: baseline)!)
    let text = try Data(contentsOf: library.transcriptURL(of: baseline)!)
    let corrected = try library.editTranscript(
      meetingID, changes: [.init(segmentID: "s2", text: "We use Kubernetes.")], expectedRevision: 0)
    precondition(corrected.record.revision == 1 && corrected.changed)
    precondition(corrected.record.segments[1].text == "We use Kubernetes.")
    precondition(corrected.record.segments.map(\.start) == baseline.segments.map(\.start))
    precondition(corrected.record.segments.map(\.end) == baseline.segments.map(\.end))
    precondition(
      corrected.record.link(to: corrected.record.segments[1])
        == baseline.link(to: baseline.segments[1]))
    try expect(try Data(contentsOf: library.audioURL(of: baseline)!) == audio)
    try expect(try Data(contentsOf: library.transcriptURL(of: baseline)!) != text)
    try expect(
      try String(contentsOf: library.transcriptURL(of: baseline)!, encoding: .utf8)
        == MeetingLibrary.transcriptText(corrected.record))
    precondition(library.search("Kubernetes").first?.segmentID == "s2")
    precondition(library.search("Kubernetes").first?.revision == 1)
    precondition(library.search("Cooper Netties").isEmpty)
    precondition(library.markdown(corrected.record).contains("We use Kubernetes."))
    let json = try MeetingLibrary.json(corrected.record)
    precondition(json["original"] == nil && json["edit_history"] == nil)
    precondition(json["transcript_file"] != nil && json["original_transcript_file"] == nil)
    guard case .array(let segments) = json["segments"] else { preconditionFailure() }
    precondition(segments[1]["segment_id"] == "s2" && segments[1]["url"] != nil)
    let unchanged = try library.editTranscript(
      meetingID, changes: [.init(segmentID: "s2", text: "We use Kubernetes.")], expectedRevision: 1)
    precondition(!unchanged.changed && unchanged.record.revision == 1)
    let stored = try Data(contentsOf: library.recordURL(for: meetingID))
    rejects("colon") {
      _ = try library.updateMeeting(
        meetingID, title: .some("Must not save"), names: ["Speaker 1": "Lena: Finance"],
        expectedRevision: 1)
    }
    rejects("Revision conflict") {
      _ = try library.editTranscript(
        meetingID, changes: [.init(segmentID: "s2", text: "Wrong stale value")], expectedRevision: 0
      )
    }
    rejects("Unknown segment") {
      _ = try library.editTranscript(
        meetingID,
        changes: [
          .init(segmentID: "s1", text: "Must not save"), .init(segmentID: "s99", text: "Bad"),
        ],
        expectedRevision: 1)
    }
    rejects("not a speaker") {
      _ = try library.updateMeeting(
        meetingID, title: .some("Must not save"), names: ["Nobody": "Unknown"], expectedRevision: 1)
    }
    rejects("more than once") {
      _ = try library.updateMeeting(
        meetingID, names: ["1": "Ada", "Speaker 1": "Grace"], expectedRevision: 1)
    }
    rejects("edited elsewhere") { try library.save(baseline) }
    try expect(try Data(contentsOf: library.recordURL(for: meetingID)) == stored)
    let storedJSON = try JSONSerialization.jsonObject(with: stored) as! [String: Any]
    precondition(storedJSON["original"] == nil && storedJSON["edit_history"] == nil)
  }

  static func testMerge(_ root: URL) throws {
    let (library, baseline) = try fixture(root)
    let merged = try library.mergeSpeakers(
      meetingID, keep: "Lena", merge: ["2"], expectedRevision: 0)
    precondition(merged.record.speakers.map(\.label) == ["Jona", "Speaker 1", "Speaker 3"])
    precondition(merged.record.segments[2].speaker == "Speaker 1")
    precondition(merged.record.speakers[1].turns == 2 && merged.record.speakers[1].seconds == 12)
    precondition(merged.record.speakers[1].source == .teams)
    let correction = try library.editTranscript(
      meetingID, changes: [.init(segmentID: "s3", text: "I will prepare launch notes.")],
      expectedRevision: 1)
    precondition(correction.record.segments[2].speaker == "Speaker 1")
    precondition(correction.record.segments[2].text == "I will prepare launch notes.")
    rejects("different assigned names") {
      _ = try library.mergeSpeakers(meetingID, keep: "1", merge: ["3"], expectedRevision: 2)
    }
    rejects("distinct speakers") {
      _ = try library.mergeSpeakers(meetingID, keep: "1", merge: ["Speaker 1"], expectedRevision: 2)
    }
    let mixed = try library.mergeSpeakers(
      meetingID, keep: "Jona", merge: ["Speaker 1"], name: "Jona", expectedRevision: 2)
    let speaker = mixed.record.speakers[0]
    precondition(speaker.source == .mix && !speaker.isLocalUser)
    precondition(speaker.identity == .unidentified && speaker.participant == nil)
    try expect(
      try String(contentsOf: library.transcriptURL(of: baseline)!, encoding: .utf8)
        == MeetingLibrary.transcriptText(mixed.record))
  }

  static func testConcurrentWriters(_ root: URL) throws {
    let (library, _) = try fixture(root)
    let group = DispatchGroup()
    let results = Results()
    for ordinal in 0..<2 {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          let other = MeetingLibrary(root: root)
          _ = try other.editTranscript(
            meetingID, changes: [.init(segmentID: "s1", text: "Writer \(ordinal)")],
            expectedRevision: 0)
          results.add(success: true)
        } catch {
          results.add(success: false, message: error.localizedDescription)
        }
      }
    }
    precondition(group.wait(timeout: .now() + 10) == .success, "Concurrent edits must not deadlock")
    precondition(results.successes == 1 && results.errors.count == 1)
    precondition(results.errors[0].contains("Revision conflict"))
    let record = try library.load(meetingID)
    precondition(record.revision == 1)
  }

  static func testWriterProcesses(_ root: URL) throws {
    let (library, _) = try fixture(root)
    let processes = (0..<2).map { index in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["--edit-fixture-writer", root.path, "Process \(index)"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = Pipe()
      return process
    }
    for process in processes { try process.run() }
    for process in processes { process.waitUntilExit() }
    precondition(processes.allSatisfy { $0.terminationReason == .exit })
    precondition(processes.map(\.terminationStatus).sorted() == [0, 3])
    let failed = processes.first { $0.terminationStatus == 3 }!
    let output = (failed.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile()
    precondition(String(decoding: output, as: UTF8.self).contains("Revision conflict"))
    let record = try library.load(meetingID)
    precondition(record.revision == 1)
  }

  static func testPersistenceFailure(_ root: URL) throws {
    let (library, _) = try fixture(root)
    let recordURL = library.recordURL(for: meetingID)
    let before = try Data(contentsOf: recordURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: library.transcripts.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: library.transcripts.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: attributes[.posixPermissions]!], ofItemAtPath: library.transcripts.path)
    }
    rejects {
      _ = try library.editTranscript(
        meetingID, changes: [.init(segmentID: "s1", text: "Must not persist")], expectedRevision: 0)
    }
    try expect(try Data(contentsOf: recordURL) == before)
    let record = try library.load(meetingID)
    precondition(record.revision == 0)
  }

  static func rejects(_ part: String? = nil, _ body: () throws -> Void) {
    do {
      try body()
      preconditionFailure("Expected failure\(part.map { ": \($0)" } ?? "")")
    } catch {
      if let part {
        precondition(error.localizedDescription.contains(part), error.localizedDescription)
      }
    }
  }

  static func expect(
    _ condition: @autoclosure () throws -> Bool,
    file: StaticString = #file, line: UInt = #line
  ) throws {
    let value = try condition()
    precondition(value, file: file, line: line)
  }

  private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successes = 0
    private(set) var errors: [String] = []

    func add(success: Bool, message: String = "") {
      lock.lock()
      defer { lock.unlock() }
      if success { successes += 1 } else { errors.append(message) }
    }
  }
}

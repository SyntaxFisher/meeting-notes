import Foundation

enum SpeakerIdentitySmoke {
  static func run() throws {
    testParticipantParser()
    testRoster()
    testComposer()
    testEchoFilter()
    try testFilesAndRetention()
    print("Teams participants, speaker names, echo filtering, and metadata sidecars: OK")
  }

  private static func testParticipantParser() {
    func parse(_ role: String, _ text: String) -> TeamsParticipantSighting? {
      TeamsParticipantParser.parse(role: role, description: text)
    }
    precondition(
      parse("AXRow", "Anna Schmidt (Unverified), Meeting guest, Unmuted")
        == TeamsParticipantSighting(
          name: "Anna Schmidt", tag: "Unverified", role: "Meeting guest", muted: false,
          source: .roster))
    precondition(
      parse("AXGroup", "Meeting Notes Dev, Organizer, Muted")
        == TeamsParticipantSighting(
          name: "Meeting Notes Dev", role: "Organizer", muted: true, source: .roster))
    precondition(parse("AXGroup", "Sam Carter (Unverified), Meeting guest")?.muted == nil)
    precondition(
      parse("AXGroup", "Bihl, Jona (Example GmbH), Presenter")?.name
        == "Bihl, Jona (Example GmbH)")
    precondition(
      parse("AXGroup", "Anna Schmidt, Besprechungsgast, Stummgeschaltet")?.role == "Meeting guest")
    precondition(
      parse("AXMenuItem", "Sam Carter (Guest), Context menu is available")
        == TeamsParticipantSighting(name: "Sam Carter", tag: "Guest", source: .tile))
    precondition(
      parse("AXMenuItem", "Myself video, Meeting Notes Dev, Unmuted, Has context menu")
        == TeamsParticipantSighting(
          name: "Meeting Notes Dev", muted: false, isLocal: true, source: .tile))
    precondition(
      parse("AXStaticText", "Sam Carter joined the call")
        == TeamsParticipantSighting(name: "Sam Carter", joined: true, source: .notice))
    precondition(parse("AXStaticText", "Sam Carter left the call")?.left == true)
    precondition(TeamsParticipantParser.section("In this meeting, 4 total") == true)
    precondition(TeamsParticipantParser.section("Waiting in lobby, 2 total") == false)
    precondition(TeamsParticipantParser.section("Others invited, 3 total") == false)
    precondition(TeamsParticipantParser.section("Anna Schmidt, Meeting guest") == nil)
    for (role, text) in [
      ("AXGroup", "Participants"), ("AXGroup", "Calling controls"),
      ("AXGroup", "Meeting Notes Dev"), ("AXStaticText", "Your microphone is muted"),
      ("AXStaticText", "Anna Schmidt (Guest)"), ("AXButton", "Leave"),
      ("AXImage", "Unmuted"), ("AXRow", ", Organizer"),
      ("AXStaticText", "2 participants joined the call"),
      ("AXMenuItem", "4 participants, Context menu is available"),
      ("AXMenuItem", "+3, Context menu is available"),
      ("AXStaticText", "Anna Schmidt and Sam Carter joined the call"),
    ] {
      precondition(parse(role, text) == nil, "Unexpected participant in \(text)")
    }
  }

  private static func testRoster() {
    var roster = ParticipantRoster()
    roster.observe(
      [
        TeamsParticipantSighting(name: "Meeting Notes Dev", isLocal: true, source: .tile),
        TeamsParticipantSighting(name: "Anna Schmidt", tag: "Guest", source: .tile),
      ], at: 1)
    precondition(!roster.sawFullRoster && roster.participants.count == 2)
    roster.observe(
      [
        TeamsParticipantSighting(name: "Meeting Notes Dev", role: "Organizer", source: .roster),
        TeamsParticipantSighting(
          name: "Anna Schmidt", tag: "Unverified", role: "Meeting guest", source: .roster),
        TeamsParticipantSighting(name: "Sam Carter", joined: true, source: .notice),
      ], at: 5)
    precondition(roster.sawFullRoster && roster.participants.count == 3)
    precondition(roster.localParticipant?.name == "Meeting Notes Dev")
    precondition(roster.localParticipant?.role == "Organizer")
    precondition(roster.remoteParticipants.map(\.name) == ["Anna Schmidt", "Sam Carter"])
    let anna = roster.participants[1]
    precondition(anna.tag == "Guest" && anna.firstSeen == 1 && anna.lastSeen == 5)
    precondition(anna.sources == [.tile, .roster])
    precondition(roster.participants[2].joinedAt == 5)
    precondition(
      roster.observe([TeamsParticipantSighting(name: "sam carter", source: .tile)], at: 9))
    precondition(roster.participants.count == 3 && roster.participants[2].lastSeen == 9)
  }

  private static func testComposer() {
    let start = Date(timeIntervalSince1970: 0)
    let utc = TimeZone(secondsFromGMT: 0)!
    let separate = TranscriptSegments(
      mode: .separateTracks, duration: 125,
      segments: [
        .init(start: 1, end: 4, source: .microphone, speaker: "local", text: "Hello everyone."),
        .init(start: 5, end: 9, source: .teams, speaker: "S2", text: "Hi."),
        .init(start: 10, end: 12, source: .teams, speaker: "S1", text: "Morning."),
        .init(start: 61, end: 63, source: .microphone, speaker: "local", text: "Bye."),
      ],
      echo: .init(lagSeconds: 0.06, coupling: 0.2, discardedSeconds: 2), engine: "fixture engine")
    var roster = ParticipantRoster()
    roster.observe(
      [
        TeamsParticipantSighting(name: "Meeting Notes Dev", isLocal: true, source: .tile),
        TeamsParticipantSighting(name: "Anna Schmidt", role: "Meeting guest", source: .roster),
        TeamsParticipantSighting(name: "Sam Carter", role: "Meeting guest", source: .roster),
      ], at: 0)
    var metadata = MeetingRecord(
      id: "1970-01-01 00.00", title: "Weekly Sync", startedAt: start, status: .transcribing)
    metadata.speakers = [MeetingSpeaker(label: "Speaker 2", name: "Kept")]
    let text = TranscriptDocument.compose(
      separate, into: &metadata, localName: "Jona", roster: roster, timeZone: utc)
    precondition(text.hasPrefix("Weekly Sync\nRecorded 1970-01-01 00:00–00:02 (2 min 5 s)\n"))
    precondition(
      text.contains(
        "- Jona: everything this Mac's microphone recorded; \"Meeting Notes Dev\" in Teams\n"))
    precondition(text.contains("- Speaker 1, Speaker 2: remote voices in the Teams audio"))
    precondition(text.contains("Participants in Teams:\n- Meeting Notes Dev (this Mac), seen"))
    precondition(text.contains("- Anna Schmidt (Meeting guest), seen 00:00:00–00:00:00"))
    precondition(
      text.hasSuffix(
        "[00:00:01] Jona: Hello everyone.\n\n[00:00:05] Speaker 1: Hi.\n\n"
          + "[00:00:10] Speaker 2: Morning.\n\n[00:01:01] Jona: Bye.\n"))
    precondition(metadata.speakers.map(\.label) == ["Jona", "Speaker 1", "Speaker 2"])
    precondition(metadata.speakers[0].identity == .localUser && metadata.speakers[0].turns == 2)
    precondition(metadata.speakers[0].participant == "Meeting Notes Dev")
    precondition(metadata.speakers[1].identity == .unidentified)
    precondition(metadata.segments.map(\.speaker) == ["Jona", "Speaker 1", "Speaker 2", "Jona"])
    precondition(metadata.transcription?.echo?.discardedSeconds == 2)
    precondition(metadata.transcription?.engine == "fixture engine")
    precondition(metadata.speakers[0].isLocalUser && !metadata.speakers[1].isLocalUser)
    precondition(metadata.speakers[2].name == "Kept", "Names assigned earlier are kept")
    precondition(metadata.participants?.participants.count == 3)
    precondition(
      metadata.durationSeconds == 125 && metadata.endedAt == start.addingTimeInterval(125))

    var single = ParticipantRoster()
    single.observe(
      [
        TeamsParticipantSighting(name: "Meeting Notes Dev", isLocal: true, source: .tile),
        TeamsParticipantSighting(name: "Sam Carter", tag: "Guest", source: .tile),
      ], at: 2)
    var namedRecord = MeetingRecord(id: "1970-01-01 00.00", startedAt: start, status: .transcribing)
    let named = TranscriptDocument.compose(
      separate, into: &namedRecord, localName: "Jona", roster: single, timeZone: utc)
    precondition(named.hasPrefix("Meeting\n"))
    precondition(named.contains("[00:00:05] Sam Carter: Hi."))
    precondition(named.contains("[00:00:10] Sam Carter: Morning."))
    precondition(namedRecord.speakers.map(\.label) == ["Jona", "Sam Carter"])
    precondition(namedRecord.speakers[1].identity == .soleRemoteParticipant)
    precondition(namedRecord.speakers[1].turns == 2)
    precondition(named.contains("Participants with a visible Teams video tile:"))

    let solo = TranscriptSegments(
      mode: .separateTracks, duration: 5,
      segments: [
        .init(start: 0.65, end: 3.87, source: .microphone, speaker: "local", text: "Hallo, Test.")
      ], engine: "fixture engine")
    var soloRecord = MeetingRecord(id: "1970-01-01 00.00", startedAt: start, status: .transcribing)
    let soloText = TranscriptDocument.compose(
      solo, into: &soloRecord, localName: "Muster, Alex (Engineering)", roster: nil, timeZone: utc)
    precondition(soloRecord.speakers.count == 1)
    precondition(soloRecord.speakers[0].identity == .localUser)
    precondition(soloRecord.speakers[0].source == .microphone)
    precondition(soloRecord.segments[0].speaker == "Muster, Alex (Engineering)")
    precondition(soloText.contains("[00:00:00] Muster, Alex (Engineering): Hallo, Test."))

    let mixed = TranscriptSegments(
      mode: .mixed, duration: 30,
      segments: [
        .init(start: 0, end: 2, source: .mix, speaker: "S1", text: "One."),
        .init(start: 3, end: 5, source: .mix, speaker: "S2", text: "Two."),
      ], engine: "fixture engine")
    var mixedRecord = MeetingRecord(
      id: "1970-01-01 00.00", title: "T", startedAt: start, status: .transcribing)
    let anonymous = TranscriptDocument.compose(
      mixed, into: &mixedRecord, localName: "Jona", roster: single, timeZone: utc)
    precondition(anonymous.contains("[00:00:00] Speaker 1: One.\n\n[00:00:03] Speaker 2: Two."))
    precondition(anonymous.contains("- Speaker 1, Speaker 2: voices in the mixed recording"))
    precondition(!anonymous.contains("Jona"))

    // Device audio is diarized like Teams audio but never named after a Teams participant.
    let device = TranscriptSegments(
      mode: .separateTracks, duration: 20,
      segments: [
        .init(start: 1, end: 3, source: .microphone, speaker: "local", text: "Hi."),
        .init(start: 4, end: 6, source: .deviceAudio, speaker: "S1", text: "Hello from Zoom."),
      ], engine: "fixture engine")
    var deviceRecord = MeetingRecord(
      id: "1970-01-01 00.00", startedAt: start, status: .transcribing, source: .deviceAudio)
    let deviceText = TranscriptDocument.compose(
      device, into: &deviceRecord, localName: "Jona", roster: single, timeZone: utc)
    precondition(deviceText.contains("[00:00:01] Jona: Hi.\n\n[00:00:04] Speaker 1: Hello"))
    precondition(
      deviceText.contains(
        "- Speaker 1: remote voices in the device audio (everything this Mac played)"))
    precondition(deviceRecord.speakers[1].source == .deviceAudio)
    precondition(deviceRecord.speakers[1].identity == .unidentified)
    let encoded = try! JSONEncoder().encode(deviceRecord)
    precondition(String(decoding: encoded, as: UTF8.self).contains("\"device-audio\""))
    precondition(try! JSONDecoder().decode(MeetingRecord.self, from: encoded) == deviceRecord)

    // One chosen app: its track is named after the app, or its bundle ID when not installed.
    let app = TranscriptSegments(
      mode: .separateTracks, duration: 20,
      segments: [
        .init(start: 1, end: 3, source: .microphone, speaker: "local", text: "Hi."),
        .init(start: 4, end: 6, source: .app, speaker: "S1", text: "Hello from the app."),
      ], engine: "fixture engine")
    var appRecord = MeetingRecord(
      id: "1970-01-01 00.00", startedAt: start, status: .transcribing,
      source: .app("com.example.not-installed"))
    let appText = TranscriptDocument.compose(
      app, into: &appRecord, localName: "Jona", roster: single, timeZone: utc)
    precondition(
      appText.contains("- Speaker 1: remote voices in the com.example.not-installed audio"),
      appText)
    precondition(appRecord.speakers[1].source == .app)
    let appJSON = try! JSONEncoder().encode(appRecord)
    precondition(
      String(decoding: appJSON, as: UTF8.self).contains(
        "\"source\":\"app:com.example.not-installed\""))
    precondition(try! JSONDecoder().decode(MeetingRecord.self, from: appJSON) == appRecord)
    var safariRecord = appRecord
    safariRecord.source = .app("com.apple.Safari")
    let safariText = TranscriptDocument.compose(
      app, into: &safariRecord, localName: "Jona", roster: nil, timeZone: utc)
    precondition(safariText.contains("remote voices in the com.apple.Safari audio"), safariText)

    var microphoneRecord = MeetingRecord(
      id: "1970-01-01 00.00", startedAt: start, status: .transcribing, source: .microphone)
    let microphoneText = TranscriptDocument.compose(
      mixed, into: &microphoneRecord, localName: "Jona", roster: nil, timeZone: utc)
    precondition(
      microphoneText.contains("- Speaker 1, Speaker 2: voices this Mac's microphone recorded"))
    for (systemAudio, source) in [
      (nil, TranscriptSegments.Source.teams), ("teams", .teams), ("device-audio", .deviceAudio),
      ("app:us.zoom.xos", .app),
    ] {
      precondition(TranscriptSegments.Source(systemAudio: systemAudio) == source)
    }

    func local(_ configured: String?, _ teams: String?, _ full: String) -> String {
      TranscriptDocument.localSpeakerName(
        configured: configured, teamsName: teams, fullUserName: full)
    }
    precondition(local("  ", nil, "A B") == "A B")
    precondition(local("Jo", "Teams Name", "A B") == "Jo")
    precondition(local(nil, "Teams Name", "A B") == "Teams Name", "Teams name wins over macOS")
    precondition(local(nil, nil, "") == "Me")
    precondition(local("a:b", nil, "") == "Me")
  }

  private static func testEchoFilter() {
    var generator = SystemRandomNumberGenerator()
    var teams = [Float](repeating: 0, count: 3_000)
    for burst in stride(from: 0, to: 2_800, by: 400) {
      for t in burst..<burst + 150 { teams[t] = Float.random(in: 0.02...0.1, using: &generator) }
    }
    var echoed = [Float](repeating: 0.0002, count: 3_000)
    for t in 3..<3_000 { echoed[t] += 0.5 * teams[t - 3] }
    for t in 200..<350 { echoed[t] = Float.random(in: 0.05...0.2, using: &generator) }
    for t in 1_220..<1_270 { echoed[t] = Float.random(in: 0.2...0.3, using: &generator) }
    let filter = EchoFilter(microphone: echoed, teams: teams)
    precondition(filter.lagFrames == 3, "lag \(filter.lagFrames)")
    precondition(abs(filter.coupling - 0.5) < 0.05, "coupling \(filter.coupling)")
    func approximately(_ ranges: [ClosedRange<Double>], _ expected: [ClosedRange<Double>]) -> Bool {
      ranges.count == expected.count
        && zip(ranges, expected).allSatisfy {
          abs($0.lowerBound - $1.lowerBound) < 0.05 && abs($0.upperBound - $1.upperBound) < 0.05
        }
    }
    precondition(approximately(filter.localRanges(start: 3, end: 11), [4...7]))
    precondition(filter.localRanges(start: 8, end: 11).isEmpty)
    precondition(approximately(filter.localRanges(start: 23, end: 27), [24.4...25.4]))

    var quiet = [Float](repeating: 0.0002, count: 3_000)
    for t in 200..<350 { quiet[t] = 0.1 }
    let headphones = EchoFilter(microphone: quiet, teams: teams)
    precondition(headphones.coupling == 0)
    precondition(headphones.localRanges(start: 8, end: 11) == [8...11])
  }

  private static func testFilesAndRetention() throws {
    precondition(MeetingFiles.title(fromStem: "2026-11-05 15.28 Weekly Sync") == "Weekly Sync")
    precondition(MeetingFiles.title(fromStem: "2026-11-05 15.28-2 A | B") == "A | B")
    precondition(MeetingFiles.title(fromStem: "2026-11-05 15.28") == nil)
    precondition(
      TranscribeCommand.parse(["a.m4a", "b.txt", "--capture", "dir", "--name", "Jona"])
        == .init(
          audio: URL(fileURLWithPath: "a.m4a"), output: URL(fileURLWithPath: "b.txt"),
          capture: URL(fileURLWithPath: "dir", isDirectory: true), name: "Jona", title: nil))
    precondition(TranscribeCommand.parse(["a.m4a"]) == nil)
    precondition(TranscribeCommand.parse(["a.m4a", "b.txt", "--name"]) == nil)
    precondition(TranscribeCommand.parse(["a.m4a", "b.txt", "--unknown", "x"]) == nil)

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
      "meeting-speaker-tests-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let existing = root.appendingPathComponent("transcript.txt")
    try MeetingFiles.publish(Data("first".utf8), to: existing)
    var refused = false
    do { try MeetingFiles.publish(Data("second".utf8), to: existing) } catch { refused = true }
    let after = try String(contentsOf: existing, encoding: .utf8)
    precondition(refused && after == "first", "A transcript is never overwritten")
    let names = try manager.contentsOfDirectory(atPath: root.path)
    precondition(names == ["transcript.txt"], "No staging files are left behind")
  }
}

import Foundation

enum SpeakerIdentitySmoke {
  static func run() throws {
    testParticipantParser()
    testSpeakingParser()
    testSpeakingFrames()
    testRoster()
    testGuestBadgeChange()
    testComposer()
    testSpeakerNaming()
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
      parse(
        "AXMenuItem",
        "Muster, Léa Marie (Design), Video ist ein, Hat die Kontrolle über Produktionstools, "
          + "Kontextmenü ist verfügbar")
        == TeamsParticipantSighting(name: "Muster, Léa Marie (Design)", source: .tile))
    precondition(
      parse(
        "AXMenuItem",
        "Video von mir selbst, Beispiel, Alex (Engineering), Hat die Kontrolle über Produktionstools, "
          + "Stummschaltung aufgehoben, Video ist ein, Frame ausfüllen, Hat Kontextmenü")
        == TeamsParticipantSighting(
          name: "Beispiel, Alex (Engineering)", muted: false, isLocal: true, source: .tile))
    precondition(
      parse("AXMenuItem", "Sam Carter, Video reconnecting, Muted, Context menu is available")
        == TeamsParticipantSighting(name: "Sam Carter", muted: true, source: .tile))
    precondition(
      parse(TeamsParticipantParser.stageTileRole, "Sam Carter - W25, Video reconnecting")?.name
        == "Sam Carter - W25")
    precondition(
      parse(
        "AXMenuItem",
        "Demo, Jan (Engineering), Videoverbindung wird wiederhergestellt, Angeheftet, "
          + "Hand erhoben, Kontextmenü ist verfügbar")
        == TeamsParticipantSighting(
          name: "Demo, Jan (Engineering)", handRaised: true, source: .tile))
    precondition(
      parse(TeamsParticipantParser.stageTileRole, "Sam Carter, Poor network quality, Pinned")?
        .name == "Sam Carter")
    precondition(
      parse(TeamsParticipantParser.stageTileRole, "Demo, Jan, Schlechte Verbindung")?.name
        == "Demo, Jan")
    precondition(
      parse("AXMenuItem", "Demo, Jan (Engineering), Stummgeschaltet, Kontextmenü ist verfügbar")?
        .muted == true)
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

  private static func testSpeakingParser() {
    precondition(
      TeamsSpeakingParser.label("Sam Carter (Guest) is speaking") == .speaking("Sam Carter"))
    precondition(
      TeamsSpeakingParser.label("Muster, Léa Marie (Design) spricht")
        == .speaking("Muster, Léa Marie (Design)"))
    precondition(TeamsSpeakingParser.label("Anna Schmidt spricht.") == .speaking("Anna Schmidt"))
    precondition(TeamsSpeakingParser.label("Nobody is speaking") == .nobody)
    precondition(TeamsSpeakingParser.label("Niemand spricht.") == .nobody)
    precondition(TeamsSpeakingParser.label("You are speaking") == .nobody)
    precondition(TeamsSpeakingParser.label("You are speaking is speaking") == .nobody)
    precondition(TeamsSpeakingParser.label("Sie sprechen. spricht") == .nobody)
    precondition(
      TeamsSpeakingParser.label("You and Sam Carter (Guest) are speaking is speaking")
        == .speaking("Sam Carter"))
    precondition(TeamsSpeakingParser.label("Sie sprechen.") == .nobody)
    precondition(
      TeamsSpeakingParser.label("You and Sam Carter (Guest) are speaking")
        == .speaking("Sam Carter"))
    precondition(
      TeamsSpeakingParser.label("Sie und Demo, Jan (Engineering) sprechen.")
        == .speaking("Demo, Jan (Engineering)"))
    for text in [" is speaking", "is speaking", "2 participants", "Shared content view", ""] {
      precondition(TeamsSpeakingParser.label(text) == nil, "Unexpected speaker in \(text)")
    }

    typealias Reading = TeamsParticipantReader.WindowReading
    let anna = TeamsParticipantSighting(name: "Anna Schmidt", tag: "Guest", source: .tile)
    let gallery = Reading(isMeeting: true, sightings: [anna], framed: ["Anna Schmidt"])
    let compact = Reading(isMeeting: true, labels: [.speaking("Sam Carter")])
    precondition(
      TeamsParticipantReader.combine([gallery], hidden: false)
        == TeamsMeetingSnapshot(participants: [anna], speakers: ["Anna Schmidt"]))
    precondition(
      TeamsParticipantReader.combine([gallery, compact], hidden: false).speakers
        == ["Sam Carter"],
      "The compact view follows the call while the gallery keeps its last frame")
    precondition(
      TeamsParticipantReader.combine([gallery, compact], hidden: false).participants == [anna])
    precondition(
      TeamsParticipantReader.combine([Reading(isMeeting: true, sightings: [anna])], hidden: false)
        .speakers == [])
    precondition(
      TeamsParticipantReader.combine([gallery, compact], hidden: true).speakers == nil,
      "A hidden Teams shows no current speaker")
    precondition(
      TeamsParticipantReader.combine(
        [Reading(isMeeting: true, framed: ["Anna Schmidt", "Sam Carter"])], hidden: false
      ).speakers == ["Anna Schmidt", "Sam Carter"],
      "Overlapping frames name everyone framed")
    precondition(TeamsParticipantReader.combine([], hidden: false) == TeamsMeetingSnapshot())
    precondition(
      TeamsParticipantReader.combine(
        [Reading(isMeeting: true, sightings: [anna]), Reading(isMeeting: true, sightings: [anna])],
        hidden: false
      ).participants == nil)
    let callee = TeamsParticipantSighting(name: "Sam Carter", joined: true, source: .notice)
    precondition(
      TeamsParticipantReader.combine(
        [gallery, Reading(isMeeting: true, isCompactView: true, sightings: [callee])],
        hidden: false
      ).participants == [anna, callee],
      "The compact view lists participants of the meeting window's own meeting")
    let stage = TeamsParticipantParser.stageTileRole
    func parse(_ role: String, _ text: String) -> TeamsParticipantSighting? {
      TeamsParticipantParser.parse(role: role, description: text)
    }
    precondition(
      parse(stage, "Sam Carter") == TeamsParticipantSighting(name: "Sam Carter", source: .tile)
        && parse(stage, "Muster, Léa (Design)")?.name == "Muster, Léa (Design)"
        && parse(stage, "Sam Carter (Guest), Muted, Context menu is available")
          == TeamsParticipantSighting(name: "Sam Carter", tag: "Guest", muted: true, source: .tile),
      "A 1:1 call names the other person's tile without a suffix")
    precondition(
      parse(stage, "Myself video, Jona Bihl")
        == TeamsParticipantSighting(name: "Jona Bihl", isLocal: true, source: .tile))
    precondition(
      parse("AXMenuItem", "Sam Carter") == nil && parse(stage, "+3") == nil
        && parse(stage, "Video is off") == nil,
      "A bare name is a tile only on the call stage")
    let oneToOne = TeamsParticipantInput(
      windows: [
        TeamsParticipantWindowInput(
          id: 1, title: "Sam Carter", minimized: true,
          items: [
            TeamsAXItem(role: "AXButton", text: "Leave"),
            TeamsAXItem(
              role: "AXImage", text: "Myself video, Jona Bihl, Unmuted, Has context menu"),
          ]),
        TeamsParticipantWindowInput(
          id: 2, title: "Meeting compact view | Sam Carter",
          items: [
            TeamsAXItem(role: "AXButton", text: "Leave"),
            TeamsAXItem(role: stage, text: "Myself video, Jona Bihl"),
            TeamsAXItem(role: stage, text: "Sam Carter"),
          ]),
      ])
    var callRoster = ParticipantRoster()
    callRoster.observe(TeamsParticipantReader.snapshot(oneToOne)?.participants ?? [], at: 1)
    precondition(
      callRoster.remoteParticipants.map(\.name) == ["Sam Carter"]
        && callRoster.localParticipant?.name == "Jona Bihl" && oneToOne.traced == oneToOne,
      "The compact view of a 1:1 call names the other person: \(callRoster)")

    var timeline = SpeakingTimeline()
    precondition(timeline.observe(["Anna"], at: 10))
    precondition(!timeline.observe(["Anna"], at: 10.8))
    precondition(!timeline.observe(["Anna"], at: 11.6))
    precondition(!timeline.observe([], at: 12.4))
    precondition(timeline.observe(["Anna"], at: 13.2), "Nobody speaking ends an interval")
    precondition(timeline.observe(["Sam"], at: 14))
    precondition(timeline.observe(["Sam"], at: 20), "A gap in the readings ends an interval")
    precondition(
      timeline.observe(["Sam", "Anna"], at: 20.8), "A second frame opens its own interval")
    precondition(!timeline.observe(["Anna", "Sam", "Anna"], at: 21.6))
    precondition(!timeline.observe(["Sam"], at: 22.4))
    precondition(
      timeline.intervals.map { "\($0.name) \($0.start)-\($0.end)" }
        == [
          "Anna 10.0-11.6", "Anna 13.2-13.2", "Sam 14.0-14.0", "Sam 20.0-22.4", "Anna 20.8-21.6",
        ], "\(timeline.intervals)")
    let decoded = try! JSONDecoder().decode(
      SpeakingTimeline.self, from: JSONEncoder().encode(timeline))
    precondition(decoded == timeline)
  }

  /// Frames Teams draws for raised hands and frames frozen in a meeting window Teams stopped
  /// updating, as a lecture recording showed them: a student who kept a hand raised read as
  /// speaking for minutes while the lecturer spoke.
  private static func testSpeakingFrames() {
    func tile(_ text: String) -> TeamsAXItem {
      .init(role: "AXMenuItem", text: text + ", Context menu is available")
    }
    func frame(_ name: String) -> TeamsAXItem { .init(role: "frame", text: name) }
    let leave = TeamsAXItem(role: "AXButton", text: "Leave")
    func speakers(_ windows: [TeamsParticipantWindowInput]) -> [String]? {
      TeamsParticipantReader.snapshot(.init(windows: windows))?.speakers
    }
    func meeting(
      _ items: [TeamsAXItem], visibility: TeamsWindowVisibility? = .visible,
      minimized: Bool = false, main: Bool = true
    ) -> TeamsParticipantWindowInput {
      .init(
        id: 1, title: "Lecture | Microsoft Teams", minimized: minimized, main: main,
        visibility: visibility, items: [leave] + items)
    }
    let lecturer = tile("Robin Lehmann, video is on, Has control of production tools")
    let raised = tile("Kim Weber - A25, Has control of production tools, muted, hand raised")
    let raisedUnmuted = tile("Kim Weber - A25, Has control of production tools, hand raised")
    precondition(
      TeamsParticipantParser.parse(role: "AXMenuItem", description: raised.text)?.handRaised
        == true
        && TeamsParticipantParser.parse(
          role: "AXMenuItem", description: "Muster, Léa, Hand erhoben, Kontextmenü ist verfügbar"
        )?.handRaised == true
        && TeamsParticipantParser.parse(role: "AXMenuItem", description: lecturer.text)?
          .handRaised == false
    )
    precondition(
      speakers([meeting([lecturer, frame("Robin Lehmann"), raised, frame("Kim Weber - A25")])])
        == ["Robin Lehmann"],
      "A raised hand's frame is not speech")
    precondition(
      speakers([meeting([lecturer, raisedUnmuted, frame("Kim Weber - A25")])]) == [],
      "Unmuted with a raised hand and one frame is still only the hand")
    precondition(
      speakers([
        meeting([lecturer, raisedUnmuted, frame("Kim Weber - A25"), frame("Kim Weber - A25")])
      ]) == ["Kim Weber - A25"],
      "A second frame on a tile with a raised hand is speech")
    precondition(
      speakers([
        meeting([
          tile("Kim Weber - A25"), frame("Kim Weber - A25"), raised, frame("Kim Weber - A25"),
        ])
      ]) == ["Kim Weber - A25"],
      "Frames count per tile, so the same person's second tile does not borrow the hand")

    let asking = [lecturer, raisedUnmuted, frame("Kim Weber - A25"), frame("Kim Weber - A25")]
    let chat = TeamsParticipantWindowInput(
      id: 2, title: "Chat | Microsoft Teams", main: true, visibility: .visible)
    for visibility in [TeamsWindowVisibility.covered, .hidden, .frozen] {
      precondition(
        speakers([meeting(asking, visibility: visibility), chat]) == nil,
        "A \(visibility) meeting window shows no current speaker")
    }
    precondition(
      speakers([meeting(asking, main: false), chat]) == ["Kim Weber - A25"],
      "A visible meeting window behind Teams chat stays current")
    let compact = TeamsParticipantWindowInput(
      id: 3, title: "Meeting compact view | Lecture", visibility: .visible,
      items: [
        leave, .init(role: TeamsParticipantParser.stageTileRole, text: "Robin Lehmann"),
        frame("Robin Lehmann"),
      ])
    precondition(
      speakers([compact, meeting(asking, visibility: .covered), chat]) == ["Robin Lehmann"],
      "The compact view follows the call while the meeting window is covered")
    precondition(
      speakers([meeting([lecturer, frame("Robin Lehmann")], minimized: true)]) == nil,
      "A minimized meeting window shows no current speaker")
    precondition(
      speakers([meeting([lecturer, frame("Robin Lehmann")], visibility: nil)])
        == ["Robin Lehmann"],
      "A window read without its visibility counts as current")
    let traced = TeamsParticipantInput(windows: [meeting(asking, visibility: .covered)]).traced
    precondition(
      traced.windows?.first?.visibility == .covered
        && traced.windows?.first?.items.filter({ $0.role == "frame" }).count == 2,
      "The trace keeps the visibility and every frame, also of a window that is not current")

    // Windows front to back in Accessibility coordinates; Teams is pid 7.
    typealias Window = TeamsWindowOcclusion.Window
    let meetingFrame = CGRect(x: 345, y: 50, width: 1228, height: 768)
    let teamsMeeting = Window(owner: 7, layer: 0, frame: meetingFrame)
    let dock = Window(owner: 2, layer: 20, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let teamsChat = Window(
      owner: 7, layer: 0, frame: CGRect(x: 0, y: 25, width: 1920, height: 1055))
    let browser = Window(owner: 9, layer: 0, frame: CGRect(x: 0, y: 25, width: 1920, height: 1055))
    func visibility(_ windows: [Window]) -> TeamsWindowVisibility {
      TeamsWindowOcclusion.visibility(of: meetingFrame, owner: 7, in: windows)
    }
    precondition(visibility([dock, teamsMeeting]) == .visible, "The Dock's overlay covers nothing")
    precondition(
      visibility([teamsChat, teamsMeeting]) == .visible, "Teams' own windows do not count")
    precondition(visibility([browser, teamsMeeting]) == .covered)
    precondition(visibility([teamsMeeting, browser]) == .visible)
    precondition(visibility([browser]) == .hidden, "A window not on screen is hidden")
    let left = Window(owner: 9, layer: 0, frame: CGRect(x: 300, y: 0, width: 700, height: 900))
    let right = Window(owner: 10, layer: 0, frame: CGRect(x: 1000, y: 0, width: 553, height: 900))
    precondition(visibility([left, right, teamsMeeting]) == .visible, "A 20 point strip shows")
    let rest = Window(owner: 10, layer: 0, frame: CGRect(x: 1550, y: 40, width: 40, height: 800))
    precondition(
      visibility([left, right, rest, teamsMeeting]) == .covered, "Two apps together cover")

    var watch = TeamsClockWatch()
    precondition(TeamsClockWatch.isClock("1:02:03") && !TeamsClockWatch.isClock("Leave"))
    precondition(!watch.isStalled(window: 1, clock: "10:42", at: 0))
    precondition(
      !watch.isStalled(window: 1, clock: "10:42", at: 10), "A time that never ran is no clock")
    precondition(!watch.isStalled(window: 1, clock: "10:43", at: 11))
    precondition(!watch.isStalled(window: 1, clock: "10:43", at: 13.5))
    precondition(watch.isStalled(window: 1, clock: "10:43", at: 14.5), "A running clock stopped")
    precondition(!watch.isStalled(window: 1, clock: "10:57", at: 30), "It runs again")
    precondition(!watch.isStalled(window: 2, clock: "10:57", at: 40), "Clocks are per window")
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

  private static func testGuestBadgeChange() {
    let base = "Robin Guest"
    let first = base + " Unverified"
    let second = base + " External unfamiliar"
    let local = "Alex"
    var roster = ParticipantRoster()
    var timeline = SpeakingTimeline()
    func observe(_ items: [TeamsAXItem], at time: Double) {
      let window = TeamsParticipantWindowInput(
        id: 1, items: [TeamsAXItem(role: "AXButton", text: "Leave")] + items)
      let snapshot = TeamsParticipantReader.snapshot(.init(windows: [window]))!
      roster.observe(snapshot.participants!, at: time)
      if let speakers = snapshot.speakers { timeline.observe(speakers, at: time) }
    }
    func tile(_ label: String) -> TeamsAXItem {
      .init(role: "AXMenuItem", text: label + ", video is on, Context menu is available")
    }
    observe(
      [
        tile("Myself video, " + local), tile(first), .init(role: "frame", text: first),
        .init(role: "AXStaticText", text: base + " joined the call"),
      ], at: 3)
    observe([tile(first), .init(role: "frame", text: first)], at: 5)
    precondition(roster.resolvedTileNames.aliases.isEmpty)
    let beforeChange = roster
    observe([tile(second), .init(role: "frame", text: second)], at: 8)
    observe([tile(second), .init(role: "frame", text: second)], at: 10)
    let confirmed = roster
    let result = TranscriptSegments(
      mode: .separateTracks, duration: 12,
      segments: [
        .init(start: 2, end: 3, source: .teams, speaker: "S1", text: "First."),
        .init(start: 4, end: 5, source: .microphone, speaker: "local", text: "Local."),
        .init(start: 7, end: 8, source: .teams, speaker: "S2", text: "Second."),
      ], engine: "fixture")
    var record = MeetingRecord(id: "fixture", startedAt: Date(), status: .complete)
    _ = TranscriptDocument.compose(
      result, into: &record, localName: local, roster: roster, speaking: timeline)
    precondition(record.segments.map(\.speaker) == [base, local, base])
    precondition(record.participants?.remoteParticipants.map(\.name) == [base])
    precondition(record.participants?.remoteParticipants.first?.lastSeen == 10)

    for conflict in [
      tile(base), TeamsAXItem(role: "AXStaticText", text: first + " joined the call"),
      TeamsAXItem(role: "AXRow", text: second + ", Presenter, Unmuted"),
    ] {
      roster = confirmed
      observe([conflict], at: 9)
      precondition(roster.resolvedTileNames.aliases.isEmpty)
    }
    roster = beforeChange
    observe([tile(first), tile(second)], at: 7)
    precondition(roster.resolvedTileNames.aliases.isEmpty)
    roster = beforeChange
    observe([tile(second)], at: 60)
    precondition(roster.resolvedTileNames.aliases.isEmpty)
    roster = ParticipantRoster()
    observe([tile(first)], at: 5)
    observe([tile(second)], at: 8)
    precondition(roster.resolvedTileNames.aliases.isEmpty)
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
      id: "19700101T000000Z", title: "Weekly Sync", startedAt: start, status: .transcribing)
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
    var namedRecord = MeetingRecord(id: "19700101T000000Z", startedAt: start, status: .transcribing)
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
    var soloRecord = MeetingRecord(id: "19700101T000000Z", startedAt: start, status: .transcribing)
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
      id: "19700101T000000Z", title: "T", startedAt: start, status: .transcribing)
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
      id: "19700101T000000Z", startedAt: start, status: .transcribing, source: .deviceAudio)
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
      id: "19700101T000000Z", startedAt: start, status: .transcribing,
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
      id: "19700101T000000Z", startedAt: start, status: .transcribing, source: .microphone)
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

  private static func testSpeakerNaming() {
    func segment(_ start: Double, _ end: Double, _ voice: String) -> TranscriptSegments.Segment {
      .init(start: start, end: end, source: .teams, speaker: voice, text: "x")
    }
    // Teams marks a speaker about a second late and releases the mark about two seconds late.
    func shown(_ name: String, _ start: Double, _ end: Double) -> SpeakingTimeline.Interval {
      .init(name: name, start: start + 1, end: end + 1.8)
    }
    let segments = [
      segment(0, 8, "S1"), segment(9, 15, "S2"), segment(16, 24, "S1"), segment(25, 26, "S2"),
      segment(27, 33, "S3"), segment(34, 40, "S2"),
      .init(start: 41, end: 44, source: .microphone, speaker: "local", text: "me"),
      segment(45, 60, "S2"),
    ]
    let timeline = SpeakingTimeline(intervals: [
      shown("Anna", 0, 8), shown("Sam", 9, 15), shown("Anna", 16, 24),
      shown("Grace", 34, 40), shown("Jona", 41, 44), shown("Sam", 45, 60),
    ])
    let names = SpeakerNaming.names(for: segments, timeline: timeline, excluded: ["Jona"])
    precondition(names[0] == "Anna" && names[1] == "Sam" && names[2] == "Anna")
    precondition(names[3] == "Sam", "A short turn without evidence takes its voice's name")
    precondition(names[4] == nil, "A voice Teams never showed keeps an anonymous label")
    precondition(names[5] == "Grace", "Direct evidence beats the voice's usual name")
    precondition(names[6] == nil, "Microphone speech is never named here")
    precondition(names[7] == "Sam")
    let contested = SpeakerNaming.names(
      for: [segment(0, 6, "S1")],
      timeline: SpeakingTimeline(intervals: [shown("Anna", 0, 3), shown("Sam", 3, 6)]))
    precondition(contested == [nil], "Two names with similar evidence name nobody")
    // One student's frame lingers, Teams is out of sight for a few seconds, and the frame comes
    // back together with the next student's, who starts speaking; the lecturer's voice cluster
    // covers both.
    let handover = SpeakingTimeline(intervals: [
      .init(name: "Kim", start: 100, end: 107.5), .init(name: "Kim", start: 111.9, end: 113.8),
      .init(name: "Tom", start: 111.9, end: 113.8), .init(name: "Robin", start: 0, end: 90),
    ])
    let handoverNames = SpeakerNaming.names(
      for: [segment(0, 80, "S1"), segment(104, 105, "S1"), segment(110.9, 112, "S1")],
      timeline: handover)
    precondition(
      handoverNames == ["Robin", "Kim", "Tom"],
      "An indicator that switched on wins over one that resumed: \(handoverNames)")
    precondition(
      SpeakerNaming.names(for: segments, timeline: SpeakingTimeline()).allSatisfy { $0 == nil })

    let start = Date(timeIntervalSince1970: 0)
    var roster = ParticipantRoster()
    roster.observe(
      [
        TeamsParticipantSighting(name: "Meeting Notes Dev", isLocal: true, source: .tile),
        TeamsParticipantSighting(name: "Anna Schmidt", source: .tile),
        TeamsParticipantSighting(name: "Sam Carter", source: .tile),
      ], at: 0)
    let result = TranscriptSegments(
      mode: .separateTracks, duration: 50,
      segments: [
        .init(start: 0, end: 8, source: .teams, speaker: "S1", text: "Guten Morgen."),
        .init(start: 9, end: 15, source: .teams, speaker: "S2", text: "Morning."),
        .init(start: 16, end: 24, source: .teams, speaker: "S3", text: "Weiter geht's."),
        .init(start: 27, end: 33, source: .teams, speaker: "S4", text: "Who is this?"),
        .init(start: 41, end: 44, source: .microphone, speaker: "local", text: "Danke."),
      ], engine: "fixture engine")
    var record = MeetingRecord(id: "19700101T000000Z", startedAt: start, status: .transcribing)
    let text = TranscriptDocument.compose(
      result, into: &record, localName: "Jona", roster: roster,
      speaking: SpeakingTimeline(intervals: [
        shown("Anna Schmidt", 0, 8), shown("Sam Carter", 9, 15), shown("Anna Schmidt", 16, 24),
        shown("Meeting Notes Dev", 41, 44),
      ]), timeZone: TimeZone(secondsFromGMT: 0)!)
    precondition(
      record.speakers.map(\.label) == ["Anna Schmidt", "Sam Carter", "Speaker 1", "Jona"])
    precondition(record.speakers[0].identity == .teamsSpeaker)
    precondition(record.speakers[0].turns == 2, "One person split into two voices is one label")
    precondition(record.speakers[0].participant == "Anna Schmidt")
    precondition(record.speakers[2].identity == .unidentified)
    precondition(text.contains("[00:00:16] Anna Schmidt: Weiter geht's."))
    precondition(text.contains("[00:00:27] Speaker 1: Who is this?"))
    precondition(text.contains("[00:00:41] Jona: Danke."))
    precondition(
      text.contains(
        "- Anna Schmidt: a voice in the Teams audio while Teams showed them speaking"))
    precondition(text.contains("- Speaker 1: remote voices in the Teams audio"))
    let encoded = try! JSONEncoder().encode(record)
    precondition(String(decoding: encoded, as: UTF8.self).contains("\"teams-speaker\""))
    precondition(try! JSONDecoder().decode(MeetingRecord.self, from: encoded) == record)

    let capture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "meeting-speaking-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: capture) }
    try! FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    try! JSONEncoder().encode(CaptureManifest(systemStart: 100.5, microphoneStart: 100))
      .write(to: capture.appendingPathComponent("capture.json"))
    try! JSONEncoder().encode(
      SpeakingTimeline(intervals: [.init(name: "Anna", start: 104, end: 109)])
    ).write(to: capture.appendingPathComponent("speaking.json"))
    precondition(
      SpeakingTimeline.load(fromCapture: capture)?.intervals == [
        .init(name: "Anna", start: 4, end: 9)
      ], "The timeline moves onto the transcript's timeline")
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

    // Teams muted after the first minute: the microphone track holds digital silence for the
    // rest of a long meeting, which must not hide the echo of the unmuted minute.
    var long = [Float](repeating: 0, count: 60_000)
    var longTeams = [Float](repeating: 0, count: 60_000)
    for burst in stride(from: 0, to: 59_800, by: 400) {
      for t in burst..<burst + 150 {
        longTeams[t] = Float.random(in: 0.02...0.1, using: &generator)
      }
    }
    for t in 3..<3_000 { long[t] = 0.0002 + 0.5 * longTeams[t - 3] }
    let muted = EchoFilter(microphone: long, teams: longTeams)
    precondition(abs(muted.coupling - 0.5) < 0.05, "muted coupling \(muted.coupling)")
    precondition(muted.localRanges(start: 8, end: 11).isEmpty)

    var quiet = [Float](repeating: 0.0002, count: 3_000)
    for t in 200..<350 { quiet[t] = 0.1 }
    let headphones = EchoFilter(microphone: quiet, teams: teams)
    precondition(headphones.coupling == 0)
    precondition(headphones.localRanges(start: 8, end: 11) == [8...11])
  }

  private static func testFilesAndRetention() throws {
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

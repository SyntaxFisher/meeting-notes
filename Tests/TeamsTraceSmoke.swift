import ApplicationServices
import Foundation

enum TeamsTraceSmoke {
  private static func line(_ object: [String: Any]) -> String {
    String(
      decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
  }

  private static func encoded<Value: Encodable>(_ value: Value) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
  }

  static func run(_ root: URL) throws {
    try testWriter(root.appendingPathComponent("trace"))
    testTracedParticipants()
    testSharingRegression()
    testReplayTiming()
    testOutgoingCall()
    testEverydayReplay()
    try testEmptySpeakerReplay(root.appendingPathComponent("empty-speakers"))
    testWindowNumbers()
    print("Teams trace: deduplicated, exported with prior state, bounded, replayed: OK")
  }

  private static func testWriter(_ directory: URL) throws {
    let trace = TeamsTrace(directory: directory)
    trace.setEnabled(true, session: ["app": "fixture"])
    let start = Date()
    for muted in [true, true, false] {
      trace.record("mute", ["state": muted ? "muted" : "unmuted"])
    }
    trace.record("recording", ["event": "recording.started"])
    let exported = trace.export(from: start.addingTimeInterval(-60), to: Date())
    let kinds = String(decoding: exported, as: UTF8.self).split(separator: "\n").map {
      (try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["k"] as! String
    }
    precondition(
      kinds == ["session", "mute", "mute", "recording"],
      "Unchanged readings are not repeated: \(kinds)")
    Thread.sleep(forTimeInterval: 0.05)
    let later = Date()
    trace.record("mute", ["state": "muted"])
    let window = String(decoding: trace.export(from: later, to: Date()), as: UTF8.self)
    precondition(
      window.contains("\"unmuted\"") && window.contains("\"muted\"")
        && window.contains("\"session\""),
      "An exported window starts from the state before it")
    trace.setEnabled(false)
    _ = trace.export(from: start, to: Date())
    precondition(
      !FileManager.default.fileExists(atPath: directory.path),
      "Turning off kept audio deletes the trace")
  }

  private static func testTracedParticipants() {
    let items = [
      TeamsAXItem(role: "AXButton", text: "Leave"),
      TeamsAXItem(role: "AXButton", text: "Q3 salaries final.xlsx"),
      TeamsAXItem(role: "AXRow", text: "Chat with Anna Schmidt, Lunch at noon? See you there"),
      TeamsAXItem(role: "AXMenuItem", text: "Reply to Anna: can you send me the numbers"),
      TeamsAXItem(role: "AXStaticText", text: "Lunch at noon? See you there"),
      TeamsAXItem(role: "AXRow", text: "In this meeting, 2 total"),
      TeamsAXItem(role: "AXRow", text: "Anna Schmidt, Meeting guest, Unmuted"),
      TeamsAXItem(role: "AXMenuItem", text: "Anna Schmidt, Context menu is available"),
      TeamsAXItem(role: "frame", text: "Anna Schmidt"),
      TeamsAXItem(role: "AXGroup", text: "Anna Schmidt is speaking"),
      TeamsAXItem(role: "AXGroup", text: "A chat message that is not a label at all"),
    ]
    let input = TeamsParticipantInput(
      windows: [TeamsParticipantWindowInput(id: 1, items: items)])
    let traced = input.traced
    precondition(
      traced.windows![0].items.map(\.text) == [
        "Leave", "In this meeting, 2 total", "Anna Schmidt, Meeting guest, Unmuted",
        "Anna Schmidt, Context menu is available", "Anna Schmidt", "Anna Schmidt is speaking",
      ],
      "Chat text, previews and file names never reach the trace")
    precondition(
      TeamsParticipantReader.snapshot(traced) == TeamsParticipantReader.snapshot(input),
      "The traced input reads like the full one")

    let meeting = TeamsWindowInput(
      id: 1, title: "Weekly | Microsoft Teams",
      buttons: [
        ["Mute mic", "Mute mic (⌘+Shift+M)"], ["Leave"],
        ["Open Q3 salaries final.xlsx"], ["React to: can you send me the numbers"],
      ],
      headings: [["Share content"], ["Anna Schmidt: Lunch at noon?"]])
    let chat = TeamsWindowInput(
      id: 2, title: "Chat | Microsoft Teams", main: true,
      buttons: [["New message from Anna Schmidt: the contract is attached"]],
      headings: [["Anna Schmidt, 10:42, I will be late"]])
    let mute = TeamsMuteInput(frontmost: true, windows: [meeting, chat])
    let tracedMute = mute.traced
    precondition(
      tracedMute.windows.map(\.buttons) == [
        [["Mute mic", "Mute mic (⌘+Shift+M)"], ["Leave"]], [],
      ]
        && tracedMute.windows.map(\.headings) == [[["Share content"]], []],
      "Only controls the mute classifier recognizes reach the trace")
    var full = TeamsMeetingWindowTracker<Int>()
    var replayed = TeamsMeetingWindowTracker<Int>()
    precondition(
      TeamsMuteClassifier.reading(mute, tracker: &full)
        == TeamsMuteClassifier.reading(tracedMute, tracker: &replayed),
      "The traced mute input reads like the full one")
  }

  /// Ordinary sessions in the order the app writes them: each reading, then the evaluation it
  /// logged, then commands and recording events.
  private static func testEverydayReplay() {
    let meeting = encoded(
      TeamsMuteInput(
        frontmost: true,
        windows: [
          TeamsWindowInput(
            id: 1, title: "Weekly | Microsoft Teams", main: true,
            buttons: [["Leave"], ["Mute mic"]])
        ]))
    func at(_ t: Double, _ kind: String, _ fields: [String: Any] = [:]) -> String {
      line(["k": kind, "t": t, "w": t + 1000].merging(fields) { $1 })
    }
    func replay(_ lines: [String]) -> TeamsReplay.Result {
      TeamsReplay.replay(Data(lines.joined(separator: "\n").utf8))
    }
    func sameRecordings(_ result: TeamsReplay.Result) -> Bool {
      !result.differences.contains { !$0.hasPrefix("mute states") }
    }
    func evaluation(_ t: Double, canStart: Bool, action: String = "") -> String {
      at(t, "auto-record", ["canStart": canStart, "action": action, "presence": "inMeeting"])
    }
    let off = replay([
      at(100, "session", ["config": ["autoRecordTeamsMeetings": false]]),
      at(101, "mute-input", meeting),
      at(102, "command", ["command": "start", "source": "panel"]),
      at(102.1, "recording", ["event": "recording.started", "trigger": "manual"]),
      at(110, "command", ["command": "stop", "source": "panel"]),
      at(110.1, "recording", ["event": "recording.stopped", "trigger": "manual"]),
    ])
    precondition(
      off.replayed.recordings == [.init(start: 102.1, end: 110.1, automatic: false)]
        && off.replayed.actions.isEmpty,
      "Without automatic recording the replay records only what the user started: \(off.replayed)")
    let blocked = replay([
      at(100, "session"), at(101, "mute-input", meeting), evaluation(101.1, canStart: false),
    ])
    precondition(blocked.replayed.recordings.isEmpty, "A blocked start stays blocked")
    let ready = replay([
      at(98, "session"), evaluation(99, canStart: false), at(100, "mute-input", meeting),
      evaluation(100.1, canStart: false), evaluation(120, canStart: true, action: "start"),
      at(121, "recording", ["event": "recording.started", "trigger": "automatic"]),
    ])
    precondition(
      ready.replayed.recordings.map(\.start) == [120] && sameRecordings(ready),
      "A start that becomes possible starts in the replay too: \(ready)")
    for withCommand in [true, false] {
      var lines = [
        at(99, "session"), at(100, "mute-input", meeting),
        evaluation(100.1, canStart: true, action: "start"),
        at(101, "recording", ["event": "recording.started", "trigger": "automatic"]),
      ]
      if withCommand { lines.append(at(119.9, "command", ["command": "stop", "source": "panel"])) }
      lines += [
        at(120, "recording", ["event": "recording.stopped", "trigger": "automatic"]),
        at(121, "mute-input", meeting), evaluation(121.1, canStart: true),
      ]
      let stopped = replay(lines)
      precondition(
        stopped.replayed.recordings == [.init(start: 100.1, end: 120, automatic: true)]
          && sameRecordings(stopped),
        "A recording the user stopped stays stopped until the meeting ends: \(stopped)")
    }
  }

  /// An open meeting window keeps its number however many other Teams windows come and go,
  /// so the window tracker still knows it while a popover hides its controls.
  private static func testWindowNumbers() {
    let registry = TeamsWindowRegistry()
    let meeting = AXUIElementCreateApplication(1)
    let id = registry.id(of: meeting)
    for round in 0..<3 {
      for pid in 0..<TeamsWindowRegistry.capacity - 1 {
        _ = registry.id(of: AXUIElementCreateApplication(pid_t(10_000 + round * 2_000 + pid)))
      }
      precondition(registry.id(of: meeting) == id, "An open window keeps its number")
    }
  }

  /// A replay whose participant readings show nobody speaking must not fall back to the
  /// speakers the archive recorded.
  private static func testEmptySpeakerReplay(_ root: URL) throws {
    let silent = TeamsParticipantInput(
      windows: [
        TeamsParticipantWindowInput(id: 1, items: [TeamsAXItem(role: "AXButton", text: "Leave")])
      ])
    let trace = [
      line(["k": "recording", "t": 10, "w": 10, "event": "recording.started", "trigger": "manual"]),
      line(["k": "participants-input", "t": 11, "w": 11].merging(encoded(silent)) { $1 }),
      line(["k": "participants-read", "t": 11.01, "w": 11.01]),
      line(["k": "participants-read", "t": 11.8, "w": 11.8]),
      line(["k": "recording", "t": 20, "w": 20, "event": "recording.stopped", "trigger": "manual"]),
    ].joined(separator: "\n")
    let result = TeamsReplay.replay(Data(trace.utf8))
    precondition(
      result.replayedSpeaking == SpeakingTimeline(),
      "Readings that show nobody give an empty timeline, not none")
    precondition(
      TeamsReplay.replay(Data(line(["k": "session", "t": 1, "w": 1]).utf8)).replayedSpeaking
        == nil, "A trace without participant readings keeps the archived timeline")
    let source = root.appendingPathComponent("archive/capture")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let archived = SpeakingTimeline(intervals: [.init(name: "Anna", start: 11, end: 18)])
    try JSONEncoder().encode(archived).write(to: source.appendingPathComponent("speaking.json"))
    let copy = root.appendingPathComponent("out/capture")
    try FileManager.default.createDirectory(
      at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ReplayCommand.copyCapture(source, to: copy, speaking: result.replayedSpeaking)
    let replayed = try JSONDecoder().decode(
      SpeakingTimeline.self, from: Data(contentsOf: copy.appendingPathComponent("speaking.json")))
    precondition(
      replayed.intervals.isEmpty, "The archived speakers do not hide a parser regression")
  }

  /// A recording that an earlier version stopped when the share dialog hid the meeting
  /// controls: the current detection keeps it running on the same input.
  private static func testSharingRegression() {
    let meeting = TeamsMuteInput(
      frontmost: true,
      windows: [
        TeamsWindowInput(
          id: 1, title: "Weekly | Microsoft Teams", main: true,
          buttons: [["Leave"], ["Mute mic"], ["Share"]])
      ])
    let sharing = TeamsMuteInput(
      frontmost: true,
      windows: [
        TeamsWindowInput(
          id: 1, title: "Weekly | Microsoft Teams", main: true, headings: [["Share content"]])
      ])
    let closed = TeamsMuteInput(frontmost: true, windows: [])
    var lines = [
      line(["k": "session", "t": 100, "w": 1000, "app": "earlier version"]),
      line(["k": "mute-input", "t": 100, "w": 1000].merging(encoded(meeting)) { $1 }),
      line(["k": "mute", "t": 100, "w": 1000, "state": "unmuted"]),
      line(["k": "auto-record", "t": 100.1, "w": 1000.1, "action": "start", "canStart": true]),
      line([
        "k": "recording", "t": 101, "w": 1001, "event": "recording.started", "trigger": "automatic",
      ]),
      line(["k": "mute-input", "t": 130, "w": 1030].merging(encoded(sharing)) { $1 }),
      line(["k": "mute", "t": 130, "w": 1030, "state": "unavailable(noMeeting)"]),
      line(["k": "auto-record", "t": 131, "w": 1031, "action": "stop", "canStart": true]),
      line([
        "k": "recording", "t": 132, "w": 1032, "event": "recording.stopped", "trigger": "automatic",
      ]),
      line(["k": "mute-input", "t": 160, "w": 1060].merging(encoded(meeting)) { $1 }),
    ]
    lines.append(line(["k": "mute-input", "t": 300, "w": 1200].merging(encoded(closed)) { $1 }))
    for time in [100.01, 130.01, 160.01, 300.01, 301.01] {
      lines.append(line(["k": "read", "t": time, "w": time + 900]))
    }
    let result = TeamsReplay.replay(Data(lines.joined(separator: "\n").utf8))
    precondition(
      result.recorded.recordings == [.init(start: 101, end: 132, automatic: true)],
      "The trace shows the earlier stop")
    precondition(
      result.replayed.recordings.count == 1 && result.replayed.recordings[0].end! > 300,
      "The current detection keeps recording through the share dialog: \(result.replayed)")
    precondition(
      result.replayed.states.map(\.value).contains("unavailable(noControl)")
        && result.differences.contains { $0.hasPrefix("stop 132.0 recorded") },
      "The replay reports where the decisions differ: \(result.differences)")
  }

  /// An outgoing call opens its window with call controls while it still rings; the window's
  /// clock shows "--:--" until the callee answers. When Teams replaces a minimized call window
  /// with its compact view, which has no clock, the stale window keeps "--:--" and the People
  /// button marks the connected call. Recording starts once the call connects, and a call
  /// nobody answers records nothing.
  private static func testOutgoingCall() {
    let controls = [["Leave"], ["Mute mic"]]
    func call(_ clock: TeamsCallClock?, compactView: [[String]]? = nil) -> TeamsMuteInput {
      var windows = [
        TeamsWindowInput(
          id: 2, title: "Called Dev", minimized: compactView != nil, main: true,
          buttons: controls + (clock == .running ? [["People"]] : []), clock: clock)
      ]
      if let compactView {
        windows.append(
          TeamsWindowInput(
            id: 3, title: "Meeting compact view | Called Dev", buttons: compactView))
      }
      return TeamsMuteInput(frontmost: compactView == nil, windows: windows)
    }
    let chat = TeamsMuteInput(
      frontmost: true, windows: [TeamsWindowInput(id: 1, title: "Chat | Called Dev", main: true)])
    var tracker = TeamsMeetingWindowTracker<Int>()
    func presence(_ input: TeamsMuteInput) -> TeamsMeetingPresence {
      TeamsMuteClassifier.reading(input, tracker: &tracker).meetingPresence
    }
    let ringing = TeamsMuteClassifier.reading(call(.pending), tracker: &tracker)
    precondition(
      ringing.state == .unmuted && ringing.meetingPresence == .connecting,
      "A ringing call mirrors mute but is not yet a meeting to record: \(ringing)")
    precondition(
      presence(call(.pending, compactView: controls)) == .connecting
        && presence(call(nil, compactView: controls)) == .connecting,
      "The compact view of a ringing call shows no clock, so the call stays connecting")
    precondition(
      presence(call(.pending, compactView: controls + [["People"]])) == .inMeeting,
      "The compact view's People button connects the call despite the stale window's clock")
    precondition(presence(chat) == .noMeeting && presence(call(nil)) == .inMeeting)
    precondition(
      presence(call(.pending)) == .connecting && presence(call(.running)) == .inMeeting,
      "The running clock connects the call")
    precondition(
      TeamsCallClock(role: "AXStaticText", labels: ["--:--"]) == .pending
        && TeamsCallClock(role: "AXStaticText", labels: ["01:02:03"]) == .running
        && TeamsCallClock(role: "AXStaticText", labels: ["Calling Called Dev"]) == nil
        && TeamsCallClock(role: "AXButton", labels: ["--:--"]) == nil)
    let legacy = try! JSONDecoder().decode(
      TeamsMuteInput.self,
      from: Data(
        #"{"frontmost":true,"windows":[{"id":2,"title":"Called Dev","main":true,"minimized":false,"buttons":[["Leave"],["Mute mic"]],"headings":[]}]}"#
          .utf8))
    var fresh = TeamsMeetingWindowTracker<Int>()
    precondition(
      TeamsMuteClassifier.reading(legacy, tracker: &fresh).meetingPresence == .inMeeting,
      "Traced inputs without the clock read as a connected call")
    let traced = call(.pending, compactView: controls + [["People"], ["Chat"]]).traced
    precondition(
      traced.windows.map(\.clock) == [.pending, nil]
        && traced.windows[1].buttons == controls + [["People"]],
      "The trace keeps the clock and the People button: \(traced)")

    func at(_ kind: String, _ time: Double, _ fields: [String: Any] = [:]) -> String {
      line(["k": kind, "t": time, "w": 1000 + time].merging(fields) { $1 })
    }
    func reading(_ time: Double, _ input: TeamsMuteInput? = nil) -> [String] {
      (input.map { [at("mute-input", time, encoded($0))] } ?? []) + [at("read", time + 0.001)]
    }
    func evaluated(_ time: Double) -> String {
      at("auto-record", time + 0.01, ["canStart": true, "action": ""])
    }
    let session = at("session", 99, ["pid": 7, "config": ["autoRecordTeamsMeetings": true]])
    var lines = [session] + reading(100, chat) + [evaluated(100)]
    lines += reading(102, call(.pending)) + [evaluated(102)]
    for time in stride(from: 102.4, through: 126.8, by: 0.4) {
      lines += reading(time) + [evaluated(time)]
    }
    let unanswered = TeamsReplay.replay(
      Data(
        (lines + reading(127, chat) + [evaluated(127)] + reading(128) + [evaluated(128)])
          .joined(separator: "\n").utf8))
    precondition(
      unanswered.replayed.recordings.isEmpty,
      "A call nobody answers records nothing: \(unanswered.replayed.recordings)")
    lines += reading(127, call(.running)) + [evaluated(127)]
    let answered = TeamsReplay.replay(Data(lines.joined(separator: "\n").utf8))
    precondition(
      answered.replayed.recordings.map { $0.start.rounded() } == [127]
        && answered.replayed.states.map(\.value) == [
          "unavailable(noMeeting)", "unmuted connecting", "unmuted",
        ],
      "Recording starts when the call connects: \(answered.replayed)")
  }

  /// Failed starts, user actions, slow readings, repeated sessions and recordings that continue
  /// a meeting, in the order and format the app traces them: a `read` line for every reading,
  /// preceded by the input when it changed.
  private static func testReplayTiming() {
    let meeting = TeamsMuteInput(
      frontmost: true,
      windows: [
        TeamsWindowInput(
          id: 1, title: "Weekly | Microsoft Teams", main: true, buttons: [["Leave"], ["Mute mic"]])
      ])
    let popover = TeamsMuteInput(
      frontmost: true, windows: [TeamsWindowInput(id: 1, title: "Weekly | Microsoft Teams")])
    let closed = TeamsMuteInput(frontmost: true, windows: [])
    func at(_ kind: String, _ time: Double, _ fields: [String: Any] = [:]) -> String {
      line(["k": kind, "t": time, "w": 1000 + time].merging(fields) { $1 })
    }
    func reading(_ time: Double, _ input: TeamsMuteInput? = nil) -> [String] {
      (input.map { [at("mute-input", time, encoded($0))] } ?? []) + [at("read", time + 0.001)]
    }
    func replay(_ lines: [String]) -> TeamsReplay.Result {
      TeamsReplay.replay(Data(lines.joined(separator: "\n").utf8))
    }
    func sameRecordings(_ result: TeamsReplay.Result) -> Bool {
      !result.differences.contains(where: {
        ["automatic recordings", "start", "stop"].contains(where: $0.hasPrefix)
      })
    }
    let session = at("session", 99, ["pid": 7, "config": ["autoRecordTeamsMeetings": true]])
    let start =
      [session] + reading(100, meeting) + [
        at("auto-record", 100.1, ["canStart": true, "action": "start"])
      ]
    let failed = replay(
      start + [
        at("recording", 100.2, ["event": "start-failed", "error": "audio device unavailable"])
      ] + reading(101) + [
        at("auto-record", 101.01, ["canStart": true, "action": "", "waiting": true]),
        at("command", 102, ["command": "start", "source": "panel"]),
        at("recording", 102.1, ["event": "recording.started", "trigger": "manual"]),
        at("command", 110, ["command": "stop", "source": "panel"]),
        at("recording", 110.1, ["event": "recording.stopped", "trigger": "manual"]),
      ])
    precondition(
      failed.replayed.recordings == failed.recorded.recordings
        && failed.replayed.recordings == [.init(start: 102.1, end: 110.1, automatic: false)],
      "A failed automatic start records nothing, and a later manual recording stays manual: "
        + "\(failed.replayed.recordings)")

    let started =
      start + [at("recording", 100.2, ["event": "recording.started", "trigger": "automatic"])]
    // The user stops while the meeting window is briefly gone; the next reading, two seconds
    // later as the app reads while not recording, shows the meeting again.
    let briefAbsence =
      started + reading(120, closed) + [
        at("auto-record", 120.01, ["canStart": false, "action": ""]),
        at("command", 120.2, ["command": "stop", "source": "panel"]),
        at("recording", 120.3, ["event": "recording.stopped", "trigger": "automatic"]),
      ] + reading(120.4) + [at("auto-record", 120.41, ["canStart": true, "action": ""])]
    let userStop = replay(
      briefAbsence + reading(122.4, meeting) + [
        at("auto-record", 122.41, ["canStart": true, "action": "", "waiting": true])
      ])
    precondition(
      userStop.replayed.recordings == [.init(start: 100.1, end: 120.3, automatic: true)]
        && sameRecordings(userStop),
      "A stop the user asked for between readings ends the recording, and the meeting it "
        + "continues starts none: \(userStop.replayed.recordings) \(userStop.differences)")
    let ended = replay(
      briefAbsence + reading(122.4) + reading(124.4) + reading(130, meeting) + [
        at("auto-record", 130.01, ["canStart": true, "action": "start"]),
        at("recording", 130.1, ["event": "recording.started", "trigger": "automatic"]),
      ])
    precondition(
      ended.replayed.recordings.map(\.start) == [100.1, 130.001] && sameRecordings(ended),
      "Unchanged readings the app made still end the meeting: \(ended.replayed.recordings)")

    // Reading Teams takes three seconds; the next reading shows the meeting again.
    let stopByUser = [
      at("command", 140, ["command": "stop", "source": "panel"]),
      at("recording", 140.1, ["event": "recording.stopped", "trigger": "automatic"]),
    ]
    let slow = replay(started + reading(120, closed) + reading(123, meeting) + stopByUser)
    precondition(
      slow.replayed.recordings == [.init(start: 100.1, end: 140.1, automatic: true)],
      "No reading is assumed while the app waited for Teams: \(slow.replayed.recordings)")

    // A popover hides the controls of the known meeting window while a setting changes, which
    // repeats the session and the unchanged input; a restart of the app forgets the window.
    let settings = at("session", 125, ["pid": 7, "config": ["autoRecordTeamsMeetings": true]])
    let changed = replay(
      started + reading(120, popover) + [settings] + reading(125.5, popover) + reading(126.5)
        + stopByUser)
    precondition(
      changed.replayed.recordings == [.init(start: 100.1, end: 140.1, automatic: true)],
      "A settings change keeps the known meeting window: \(changed.replayed.recordings)")
    let restarted = replay(
      started + reading(120, popover) + [
        at("session", 125, ["pid": 8, "config": ["autoRecordTeamsMeetings": true]])
      ] + reading(125.5, popover) + reading(126.5))
    precondition(
      restarted.replayed.recordings == [.init(start: 100.1, end: 125, automatic: true)]
        && restarted.replayed.states.last?.value == "unavailable(noMeeting)",
      "A restarted app knows no window from before: \(restarted.replayed)")

    // Anna keeps speaking while the user stops and records again in the same meeting; the
    // unchanged participant input is not traced again.
    let anna = TeamsParticipantInput(
      windows: [
        TeamsParticipantWindowInput(
          id: 1,
          items: [
            TeamsAXItem(role: "AXButton", text: "Leave"),
            TeamsAXItem(role: "AXGroup", text: "Anna Schmidt is speaking"),
          ])
      ])
    func speakerReads(_ from: Double, _ to: Double) -> [String] {
      stride(from: from, through: to, by: 0.8).map { at("participants-read", $0) }
    }
    let twice = replay(
      [at("recording", 1, ["event": "recording.started", "trigger": "manual"])]
        + [at("participants-input", 2, encoded(anna))] + speakerReads(2.001, 9.6)
        + [
          at("recording", 10, ["event": "recording.stopped", "trigger": "manual"]),
          at("recording", 100, ["event": "recording.started", "trigger": "manual"]),
        ] + speakerReads(100.5, 119.7)
        + [at("recording", 120, ["event": "recording.stopped", "trigger": "manual"])])
    precondition(
      twice.replayedSpeaking?.intervals.map(\.name) == ["Anna Schmidt", "Anna Schmidt"]
        && twice.replayedSpeaking!.intervals[1].start == 100.5
        && twice.replayedSpeaking!.intervals[1].end > 119,
      "The second recording in the same meeting keeps its speaker: \(twice.speaking)")
  }

}

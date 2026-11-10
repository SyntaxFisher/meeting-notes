import Foundation

enum AgentEditingSmoke {
  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mn-mcp-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MeetingLibrary(root: root)
    var bridge = AgentBridge(library: library)
    bridge.configFile = root.appendingPathComponent("config.json")
    bridge.socket = root.appendingPathComponent("absent.sock")
    bridge.allowsAppLaunch = false
    let server = MCPServer(bridge: bridge)
    func call(_ name: String, _ args: JSONValue = [:], error: Bool = false) -> String {
      let request: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": ["name": .string(name), "arguments": args],
      ]
      let response = server.handle(
        line: String(decoding: try! JSONCoding.encoder().encode(request), as: UTF8.self))![
          "result"]!
      precondition(response["isError"] == .bool(error), "\(name): \(response)")
      precondition(response["structuredContent"] == nil)
      guard case .array(let content) = response["content"] else { preconditionFailure() }
      return content.first!["text"]!.stringValue!
    }
    func cursor(_ text: String) -> String? {
      text.components(separatedBy: "\n").first(where: { $0.hasPrefix("next_cursor: ") }).map {
        String($0.dropFirst(13))
      }
    }
    precondition(call("get_meeting") == "No meetings yet.")
    var record = MeetingRecord(id: "20261106T080000Z", startedAt: Date(), status: .complete)
    record.segments = [
      .init(start: 0, end: 5, speaker: "Speaker 1", text: "We deploy the checkout on Tuesday."),
      .init(start: 5, end: 10, speaker: "Speaker 2", text: "Mira checks the payment flow."),
      .init(start: 5.05, end: 11, speaker: "Speaker 3", text: "Cooper Netties hosts it."),
    ]
    record.speakers = MeetingRecord.speakers(for: record.segments)
    record.durationSeconds = 11
    record.transcriptFile = record.id + ".txt"
    record.audioFile = record.id + ".m4a"
    try library.save(record)
    try Data("transcript".utf8).write(
      to: library.transcripts.appendingPathComponent(record.transcriptFile!))
    try FileManager.default.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: library.audios.appendingPathComponent(record.audioFile!))
    do {
      let openedURL = root.appendingPathComponent("opened-url.txt")
      let endpoint = ControlServer(socket: bridge.socket) { request in
        guard request.command == "open_meeting",
          let value = request.arguments["url"]?.stringValue
        else { return .failure("Unexpected command.") }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("refuse-open").path) {
          return .failure("The meeting window is unavailable.")
        }
        try? Data(value.utf8).write(to: openedURL)
        return ControlResponse(
          ok: true, meetingId: MeetingLink(url: URL(string: value)!)?.meetingID)
      }
      try endpoint.start()
      defer { endpoint.stop() }
      let original = try Data(contentsOf: library.recordURL(for: record.id))
      let opened = call("open_meeting")
      precondition(opened.contains("url: " + record.link.string))
      precondition(opened.contains("Title: " + record.displayTitle))
      precondition(try! String(contentsOf: openedURL, encoding: .utf8) == record.link.string)
      let passage = call("open_meeting", ["passage": "s2"])
      precondition(passage.hasSuffix("?p=s2"))
      let time = call("open_meeting", ["meeting_id": .string(record.id), "at": "00:00:06"])
      precondition(time.hasSuffix("?t=6"))
      try FileManager.default.removeItem(at: openedURL)
      for invalid: JSONValue in [
        ["passage": "s0"], ["passage": "s999"], ["at": "12"], ["at": "NaN"],
        ["passage": "s1", "at": "0"], ["meeting_id": "missing"], ["at": 5],
      ] {
        _ = call("open_meeting", invalid, error: true)
      }
      _ = call("get_meeting")
      precondition(!FileManager.default.fileExists(atPath: openedURL.path))
      let pending = MeetingRecord(
        id: "20261106T080100Z", startedAt: record.startedAt.addingTimeInterval(60),
        status: .transcribing)
      try library.save(pending)
      precondition(call("open_meeting").contains("meeting_id: " + pending.id))
      precondition(call("open_meeting", ["meeting_id": "latest"]).hasSuffix(pending.link.string))
      precondition(try! String(contentsOf: openedURL, encoding: .utf8) == pending.link.string)
      try FileManager.default.removeItem(at: library.recordURL(for: pending.id))
      try Data().write(to: root.appendingPathComponent("refuse-open"))
      precondition(call("open_meeting", error: true).contains("window is unavailable"))
      precondition(try! Data(contentsOf: library.recordURL(for: record.id)) == original)
    }
    precondition(call("open_meeting", error: true).contains("App controls are unavailable"))
    let titleRequest = "This meeting has no title."
    let summaryRequest = "This meeting has no saved description."
    let correctionRequest = "Review the passages you read"
    let followUp = "Required follow-up from the user's enabled Meeting Notes settings"
    func metadata() -> [JSONValue] {
      ["initialize", "tools/list"].map { method in
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": .string(method)]
        return server.handle(
          line: String(decoding: try! JSONCoding.encoder().encode(request), as: UTF8.self))![
            "result"]!
      }
    }
    let initialMetadata = metadata()
    let read = call("get_meeting")
    precondition(read.contains(titleRequest) && !read.contains(correctionRequest))
    precondition(read.contains(summaryRequest))
    precondition(
      read.range(of: followUp)!.lowerBound > read.range(of: "End of transcript.")!.lowerBound)
    precondition(read.contains("a separate editing request is not needed"))
    precondition(read.contains("Do this even for a targeted question"))
    precondition(read.contains("Batch transcript corrections first"))
    precondition(read.contains("recording_path:"))
    precondition(read.contains("url: \(record.link.string)") && read.contains("s3 00:00:05"))
    precondition(!read.contains("title_source") && !read.contains("original_segments"))
    _ = call("get_meeting", ["format": "json"], error: true)
    _ = call("start_recording", ["source": "auto"], error: true)
    _ = call("list_meetings", ["queries": ["checkout"]], error: true)
    _ = call("get_meeting", ["passage": "s2", "at": "0"], error: true)
    let passage = call("get_meeting", ["passage": "s3", "context": 0])
    precondition(passage.contains("Cooper Netties") && !passage.contains("We deploy"))
    _ = call("get_meeting", ["at": "00:01:00"], error: true)
    let at = call("get_meeting", ["at": "00:00:05", "context": 0])
    precondition(at.contains("Mira checks"))
    let searched = call("search_meetings", ["queries": ["checkout"]])
    precondition(searched.contains("s1") && searched.contains("(excerpt)"))
    let alternatives = call("search_meetings", ["queries": ["nonexistent", "checkout", "cooper"]])
    precondition(alternatives.contains("s1 ") && alternatives.contains("s3 "))
    _ = call("search_meetings", [:], error: true)
    _ = call("search_meetings", ["query": "checkout"], error: true)
    _ = call("search_meetings", ["queries": []], error: true)
    _ = call("search_meetings", ["queries": ["checkout", " "]], error: true)
    _ = call("search_meetings", ["queries": "checkout"], error: true)
    let named = call(
      "update_meeting",
      [
        "meeting_id": .string(record.id), "revision": 0,
        "topic": "Checkout migration deployment plan",
      ])
    precondition(
      named.contains("Checkout migration deployment plan") && named.contains("revision: 1"))
    precondition(!call("get_meeting").contains(titleRequest))
    _ = call(
      "edit_transcript",
      [
        "meeting_id": .string(record.id), "revision": 0,
        "changes": [["segment_id": "s3", "text": "Kubernetes hosts it."]],
      ], error: true)
    _ = call(
      "edit_transcript",
      [
        "meeting_id": "latest", "revision": 1,
        "changes": [["segment_id": "s3", "text": "Kubernetes hosts it."]],
      ], error: true)
    _ = call(
      "edit_transcript",
      [
        "meeting_id": .string(record.id), "revision": 1,
        "changes": [["segment_id": "s3", "text": "Kubernetes hosts it."]],
      ])
    _ = call(
      "merge_speakers",
      [
        "meeting_id": .string(record.id), "revision": 2,
        "keep": "Speaker 2", "merge": ["Speaker 3"], "name": "Mira",
      ])
    let merged = try library.load(record.id)
    precondition(merged.speakers.count == 2 && merged.revision == 3)
    var config = AppConfig()
    config.agentsMayCorrectTranscripts = true
    try config.encoded().write(to: bridge.configFile)
    precondition(call("get_meeting").contains(correctionRequest))
    precondition(metadata() == initialMetadata)
    precondition(call("get_meeting").contains("every speech-recognition mistake"))
    config.agentsMayCorrectTranscripts = false
    config.agentsMayNameMeetings = false
    try config.encoded().write(to: bridge.configFile)
    precondition(metadata() == initialMetadata)
    precondition(!call("get_meeting").contains(correctionRequest))
    precondition(!call("get_meeting").contains(titleRequest))
    var untitled = record
    untitled.id = "20261105T080000Z"
    untitled.startedAt = record.startedAt.addingTimeInterval(-86400)
    untitled.audioFile = nil
    untitled.transcriptFile = nil
    try library.save(untitled)
    precondition(
      !call("get_meeting", ["meeting_id": .string(untitled.id)]).contains(titleRequest))
    _ = call(
      "update_meeting",
      ["meeting_id": .string(untitled.id), "revision": 0, "topic": "Checkout deployment plan"])
    let explicitlyNamed = try library.load(untitled.id)
    precondition(explicitlyNamed.title == "Checkout deployment plan")
    _ = call(
      "update_meeting",
      ["meeting_id": .string(record.id), "revision": 3, "topic": "Another topic"], error: true)
    // Explicit corrections remain available when automatic nudges are disabled.
    _ = call(
      "edit_transcript",
      [
        "meeting_id": .string(record.id), "revision": 3,
        "changes": [["segment_id": "s1", "text": "We deploy on Wednesday."]],
      ])
    config.agentsMayNameMeetings = true
    try config.encoded().write(to: bridge.configFile)
    var teams = record
    teams.id = "20261106T090000Z"
    teams.title = "Mittagspause"
    teams.titleSource = .teams
    teams.startedAt = record.startedAt.addingTimeInterval(3600)
    teams.audioFile = nil
    teams.transcriptFile = nil
    teams.segments = [
      .init(start: 0, end: 4, speaker: "Speaker 1", text: "Hallo, hallo, Test 1, 2, 3.")
    ]
    try library.save(teams)
    let teamsRead = call("get_meeting", ["meeting_id": .string(teams.id)])
    precondition(
      !teamsRead.contains(titleRequest) && teamsRead.contains(summaryRequest))
    _ = call(
      "update_meeting",
      [
        "meeting_id": .string(teams.id), "revision": 0,
        "topic": "Testaufnahme", "summary": "Kurzer Aufnahmetest.",
      ], error: true)
    let unchangedTeams = try library.load(teams.id)
    precondition(unchangedTeams.revision == 0)
    let summarized = call(
      "update_meeting",
      [
        "meeting_id": .string(teams.id), "revision": 0,
        "summary": "Kurzer  Test der Aufnahme.\nEs wurden die Zahlen eins bis drei gesprochen.",
      ])
    precondition(summarized.contains("revision: 1") && summarized.contains("Title: Mittagspause"))
    let saved = try library.load(teams.id)
    precondition(
      saved.titleSource == .teams
        && saved.summary
          == "Kurzer Test der Aufnahme. Es wurden die Zahlen eins bis drei gesprochen."
    )
    let summarizedRead = call("get_meeting", ["meeting_id": .string(teams.id)])
    precondition(
      summarizedRead.contains("Summary: Kurzer Test") && !summarizedRead.contains(summaryRequest)
    )
    precondition(!summarizedRead.contains(followUp))
    precondition(!summarizedRead.contains("recording_path:"))
    _ = call(
      "update_meeting", ["meeting_id": .string(teams.id), "revision": 0, "summary": "Stale."],
      error: true)
    _ = call(
      "update_meeting", ["meeting_id": .string(teams.id), "revision": 1, "summary": " "],
      error: true)
    _ = call(
      "update_meeting",
      [
        "meeting_id": .string(teams.id), "revision": 1,
        "summary": .string(String(repeating: "x", count: 1001)),
      ], error: true)
    let correctedReply = call(
      "edit_transcript",
      [
        "meeting_id": .string(teams.id), "revision": 1,
        "changes": [["segment_id": "s1", "text": "Hallo, Test eins bis vier."]],
      ])
    precondition(correctedReply.contains(summaryRequest) && correctedReply.contains("revision: 2"))
    precondition(!correctedReply.contains(titleRequest))
    let correctedTeams = try library.load(teams.id)
    precondition(correctedTeams.summary == nil)
    config.agentsMaySummarizeMeetings = false
    try config.encoded().write(to: bridge.configFile)
    precondition(metadata() == initialMetadata)
    precondition(
      !call("get_meeting", ["meeting_id": .string(teams.id)]).contains(summaryRequest))
    _ = call(
      "update_meeting",
      [
        "meeting_id": .string(teams.id), "revision": 2,
        "summary": "Es wurden die Zahlen eins bis vier gesprochen.",
      ])
    let explicitSummary = try library.load(teams.id)
    precondition(explicitSummary.summary != nil)
    config.agentsMaySummarizeMeetings = true
    try config.encoded().write(to: bridge.configFile)
    let status = call("get_status")
    for hidden in ["config_path", "settings", "retention", "meetings_root"] {
      precondition(!status.contains(hidden))
    }
    let list = call("list_meetings", ["limit": 1])
    let listNext = cursor(list)!
    precondition(call("list_meetings", ["cursor": .string(listNext)]).contains(record.id))
    _ = call("list_meetings", ["cursor": .string(listNext), "limit": 1], error: true)
    _ = call("get_meeting", ["cursor": .string(listNext)], error: true)
    _ = call("get_meeting", ["cursor": "malformed"], error: true)
    _ = call("list_meetings", ["status": "nonsense"], error: true)
    // Whole passages paginate without loss; exceptional giant Unicode passages split safely.
    var long = record
    long.id = "20261106T100000Z"
    long.title = "Long review"
    long.titleSource = .user
    long.startedAt = record.startedAt.addingTimeInterval(7200)
    long.segments = (0..<240).map {
      .init(
        start: Double($0 * 10), end: Double($0 * 10 + 9), speaker: "Speaker 1",
        text: "Unique passage \($0). " + String(repeating: "é水 ", count: 20))
    }
    long.segments.append(
      .init(
        start: 2400, end: 2500, speaker: "Speaker 1", text: String(repeating: "é水 ", count: 9000)))
    long.speakers = MeetingRecord.speakers(for: long.segments)
    long.durationSeconds = 2500
    long.transcriptFile = nil
    long.audioFile = nil
    try library.save(long)
    var page = call("get_meeting", ["meeting_id": .string(long.id)])
    precondition(page.range(of: followUp)!.lowerBound > page.range(of: "next_cursor:")!.lowerBound)
    let firstCursor = cursor(page)!
    var combined = page
    var pages = 1
    while let next = cursor(page) {
      page = call("get_meeting", ["cursor": .string(next)])
      precondition(page.contains(summaryRequest) && !page.contains(titleRequest))
      combined += "\n" + page
      pages += 1
      precondition(pages < 20)
    }
    for index in 0..<240 {
      precondition(combined.components(separatedBy: "Unique passage \(index).").count == 2)
    }
    precondition(pages > 3 && combined.contains("partial; continue before editing"))
    let targeted = call(
      "get_meeting", ["meeting_id": .string(long.id), "passage": "s230", "context": 1])
    precondition(
      targeted.contains("Unique passage 229.") && !targeted.contains("Unique passage 0."))
    precondition(targeted.contains(summaryRequest))
    precondition(targeted.contains("read from the beginning"))
    var empty = long
    empty.segments = []
    precondition(
      try! MeetingAgentView.page(
        empty, library: library, arguments: [:], namesMeetings: true,
        correctsTranscripts: true, summarizesMeetings: true
      ).text.contains(followUp) == false)
    var processing = long
    processing.status = .transcribing
    precondition(
      try! MeetingAgentView.page(
        processing, library: library, arguments: [:], namesMeetings: true,
        correctsTranscripts: true, summarizesMeetings: true
      ).text.contains(followUp) == false)
    _ = try library.editTranscript(
      long.id, changes: [.init(segmentID: "s1", text: "Changed")], expectedRevision: 0)
    _ = call("get_meeting", ["cursor": .string(firstCursor)], error: true)
    let allSearch = call("search_meetings", ["queries": ["Unique passage"], "limit": 3])
    precondition(cursor(allSearch) != nil)
    let continued = call("search_meetings", ["cursor": .string(cursor(allSearch)!)])
    precondition(continued.contains("s5") && !continued.contains("s2 "))
    let german = String(repeating: "Straße ", count: 150) + "Sonderpreis"
    precondition(MeetingLibrary.snippet(german, around: "sonderpreis").contains("Sonderpreis"))
    precondition(MeetingLibrary.snippet(german, around: "strasse").contains("Straße"))
    precondition(combined.contains("final part"))
    print(
      "MCP: text output, titles/nudges, edits, paths, navigation, cursors, Unicode and stale reads: OK"
    )
  }
}

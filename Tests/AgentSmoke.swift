import Foundation

/// Device-free checks for meeting records, search, the control socket and the MCP server.
enum AgentSmoke {
  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mn-agent-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MeetingLibrary(root: root)
    library.timeZone = TimeZone(identifier: "Europe/Berlin")!
    try testRecords(library)
    print("Meeting records: legacy parsing, ids, rendering and speaker names: OK")
    try testSearch(library)
    print("Transcript search: all terms, diacritics, timestamps and filters: OK")
    testDateFilter()
    print("Date filters: ISO dates, today, yesterday and relative ages: OK")
    try testControlChannel(root)
    print("Control socket: owner-only file, request/response round trip, not running: OK")
    try testWait(library, root: root)
    print("Waiting for a transcript by meeting id or for the next one: OK")
    try testMCP(library, root: root)
    print("MCP: initialize, tool catalog, tool calls, resources and JSON-RPC errors: OK")
    try testCommandLine()
    print("Command line: options, flags, formatting, agent setup quoting and shim: OK")
  }

  static let legacyText = """
    [00:00:20] Speaker 1: Hi, can you hear me? I just joined from the browser.

    [00:00:26] Speaker 2: Yes, I can hear you clearly.

    [00:00:33] Speaker 2: Guten Morgen zusammen, wir sprechen über die Aufnahmefunktion.

    [00:01:05] Speaker 1: The budget review moves to Thursday.

    """

  static func testRecords(_ library: MeetingLibrary) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: library.transcripts, withIntermediateDirectories: true)
    try manager.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try legacyText.write(
      to: library.transcripts.appendingPathComponent("2026-11-03 17.39 Weekly Sync.txt"),
      atomically: true, encoding: .utf8)
    let migration = try MeetingFilesMigration.run(root: library.root, timeZone: library.timeZone)
    let legacy = migration.migrated["2026-11-03 17.39"]!
    try "ignored".write(
      to: library.transcripts.appendingPathComponent("notes.txt"), atomically: true,
      encoding: .utf8)

    let parsed = try library.load(legacy)
    precondition(parsed.status == .complete && parsed.title == "Weekly Sync")
    precondition(parsed.segments.count == 4)
    precondition(parsed.segments[0].start == 20 && parsed.segments[0].end == 26)
    precondition(parsed.segments[3].start == 65 && parsed.segments[3].text.hasSuffix("Thursday."))
    precondition(parsed.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = library.timeZone
    (components.year, components.month, components.day) = (2026, 11, 3)
    (components.hour, components.minute) = (17, 39)
    precondition(parsed.startedAt == components.date!)

    let fresh = "20261105T151700Z"
    let segments = [
      MeetingSegment(
        start: 1.5, end: 4.25, speaker: "Jona", text: "Let's start with the café menu."),
      MeetingSegment(start: 4.25, end: 9, speaker: "Speaker 1", text: "The budget is fine."),
    ]
    var record = MeetingRecord(
      id: fresh, title: "Design Review", startedAt: Date(timeIntervalSince1970: 1_793_888_220),
      status: .complete, source: .teams, trigger: .manual)
    record.endedAt = Date(timeIntervalSince1970: 1_793_888_229)
    record.durationSeconds = 9
    record.segments = segments
    record.speakers = [
      MeetingSpeaker(label: "Jona", isLocalUser: true, identity: .localUser, source: .microphone),
      MeetingSpeaker(label: "Speaker 1", source: .teams),
    ]
    record.transcriptFile = "20261105T151700Z.txt"
    try library.save(record)
    try MeetingLibrary.transcriptText(record).write(
      to: library.transcripts.appendingPathComponent(record.transcriptFile!), atomically: true,
      encoding: .utf8)
    let saved = String(decoding: try Data(contentsOf: library.recordURL(for: fresh)), as: UTF8.self)
    for key in [
      "\"schema_version\" : 1", "\"started_at\"", "\"duration_seconds\" : 9",
      "\"source\" : \"teams\"", "\"trigger\" : \"manual\"", "\"segments\"",
      "\"is_local_user\" : true",
    ] {
      precondition(saved.contains(key), "Missing \(key) in record")
    }
    var loaded = try library.load(fresh)
    precondition(loaded.segments == segments && loaded.updatedAt != nil)
    loaded.updatedAt = nil
    precondition(loaded == record)

    let pending = "20261105T160000Z"
    try library.save(
      MeetingRecord(
        id: pending, startedAt: Date(timeIntervalSince1970: 1_793_890_800), status: .transcribing))

    precondition(library.meetings().map(\.id) == [pending, fresh, legacy])
    try expect(try library.resolve("latest") == fresh)
    try expect(try library.resolve(String(legacy.prefix(8))) == legacy)
    try expect(try library.resolve("design") == fresh)
    do {
      _ = try library.resolve("20261105")
      preconditionFailure("Ambiguous prefixes must not resolve")
    } catch {
      precondition(error.localizedDescription.contains("matches 2 meetings"))
    }
    precondition((try? library.resolve("../state")) == nil)

    let summary = library.summary(of: try library.load(fresh))
    precondition(summary.segmentCount == 2 && summary.wordCount == 10)
    precondition(summary.recordPath != nil && summary.audioPath == nil)
    precondition(summary.transcriptPath?.hasSuffix("/20261105T151700Z.txt") == true)

    let renamed = try library.renameSpeakers(fresh, names: ["1": "Ada"])
    precondition(renamed.speakers.map(\.name) == [nil, "Ada"])
    do {
      try library.renameSpeakers(fresh, names: ["Speaker 9": "Nobody"])
      preconditionFailure("Unknown labels must be rejected")
    } catch {}
    do {
      try library.renameSpeakers(pending, names: ["1": "Ada"])
      preconditionFailure("Incomplete meetings cannot be renamed")
    } catch {}
    let text = try library.render(try library.load(fresh), as: .text)
    precondition(text.contains("[00:00:04] Ada: The budget is fine."))
    let original = try String(
      contentsOf: library.transcripts.appendingPathComponent(record.transcriptFile!),
      encoding: .utf8)
    precondition(!original.contains("Speaker 1:"), "Renaming updates the transcript text")
    try library.renameSpeakers(fresh, names: ["Speaker 1": ""])
    try expect(try library.load(fresh).speakers[1].name == nil)
    try library.renameSpeakers(fresh, names: ["Speaker 1": "Ada"])

    let legacyRenamed = try library.renameSpeakers(legacy, names: ["2": "Grace"])
    precondition(manager.fileExists(atPath: library.recordURL(for: legacy).path))
    precondition(legacyRenamed.segments.count == 4)
    try expect(try library.load(legacy).displayName(for: "Speaker 2") == "Grace")
    try expect(try library.load(legacy).title == "Weekly Sync")

    let markdown = library.markdown(try library.load(fresh))
    for line in [
      "---", "id: \"20261105T151700Z\"", "title: \"Design Review\"", "status: complete",
      "  - label: \"Speaker 1\"", "    name: \"Ada\"", "    local_user: true", "# Design Review",
      "url: \"https://meeting-notes.jonabihl.dev/meeting/20261105T151700Z\"",
      "[00:00:04](https://meeting-notes.jonabihl.dev/meeting/20261105T151700Z?t=4.2) **Ada:** The budget is fine.",
    ] {
      precondition(markdown.contains(line), "Missing \(line) in markdown")
    }
    try expect(library.markdown(try library.load(pending)).contains("_Transcribing._"))
    try library.setTitle(fresh, title: "  Design Review v2 ")
    try expect(try library.load(fresh).title == "Design Review v2")
    try expect(try library.resolve("v2") == fresh)
    try expect(library.transcriptURL(of: try library.load(fresh)) != nil)
    do {
      try library.setTitle(pending, title: "Too early")
      preconditionFailure("In-progress meetings are retitled through the app")
    } catch {}
  }

  static func testSearch(_ library: MeetingLibrary) throws {
    let hits = library.search(["BUDGET"])
    precondition(hits.map(\.meetingId) == ["20261105T151700Z", "20261103T163900Z"])
    precondition(hits[1].timestamp == "00:01:05" && hits[1].start == 65)
    precondition(library.search(["cafe menu"]).first?.speaker == "Jona")
    precondition(library.search(["uber aufnahmefunktion"]).first?.speaker == "Grace")
    precondition(library.search(["budget thursday"]).count == 1)
    precondition(library.search(["budg, THURS!"]).count == 1)
    precondition(library.search(["ursday"]).isEmpty, "Terms match at word starts only")
    precondition(library.search(["budget nonexistent"]).isEmpty)
    let either = library.search(["nonexistent", "cafe menu", "aufnahmefunktion"])
    precondition(either.map(\.speaker) == ["Jona", "Grace"], "Any query matches a passage")
    precondition(library.search(["budget", "budget thursday"]).count == hits.count)
    precondition(library.search(["", "  "]).isEmpty)
    precondition(library.search(["budget"], limit: 1).count == 1)
    precondition(library.search(["budget"], meeting: "20261103T163900Z").count == 1)
    let since = try DateFilter.parse("2026-11-04")
    precondition(library.search(["budget"], since: since).count == 1)
    precondition(
      library.list(queries: ["grace aufnahmefunktion"]).map(\.id) == ["20261103T163900Z"])
    precondition(
      library.list(queries: ["nonexistent", "grace aufnahmefunktion"]).map(\.id) == [
        "20261103T163900Z"
      ])
    precondition(library.list(limit: 1).count == 1)
    precondition(library.list(until: since).map(\.id) == ["20261103T163900Z"])
    precondition(library.list(status: [.transcribing]).map(\.id) == ["20261105T160000Z"])
    let long =
      String(repeating: "word ", count: 100) + "needle " + String(repeating: "tail ", count: 100)
    let snippet = MeetingLibrary.snippet(long, around: "needle")
    precondition(snippet.hasPrefix("...") && snippet.hasSuffix("...") && snippet.contains("needle"))
  }

  static func testDateFilter() {
    let now = Date(timeIntervalSince1970: 1_793_900_000)
    precondition(try! DateFilter.parse("7d", now: now) == now.addingTimeInterval(-7 * 86_400))
    precondition(try! DateFilter.parse("90m", now: now) == now.addingTimeInterval(-5_400))
    precondition(try! DateFilter.parse("today", now: now) == Calendar.current.startOfDay(for: now))
    precondition(
      try! DateFilter.parse("2026-11-05T10:00:00Z") == Date(timeIntervalSince1970: 1_793_872_800))
    precondition((try? DateFilter.parse("soon")) == nil)
  }

  static func testControlChannel(_ root: URL) throws {
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mn-\(UUID().uuidString.prefix(8)).sock")
    expectError({ _ = try ControlClient.send(ControlRequest(command: "status"), socket: socket) })
    let server = ControlServer(socket: socket) { request in
      ControlResponse(
        ok: request.command == "start", message: request.arguments["title"]?.stringValue,
        meetingId: request.command == "start" ? "20261105T151700Z" : nil)
    }
    try server.start()
    defer { server.stop() }
    let mode =
      try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as! Int
    precondition(mode & 0o077 == 0, "Socket must be owner-only, got \(String(mode, radix: 8))")
    let response = try ControlClient.send(
      ControlRequest(command: "start", arguments: ["title": "Weekly Sync"]), socket: socket)
    precondition(response.ok && response.message == "Weekly Sync")
    precondition(response.meetingId == "20261105T151700Z")
    try expect(try !ControlClient.send(ControlRequest(command: "nope"), socket: socket).ok)
    precondition(ControlClient.isServing(socket: socket))
    expectError { try ControlServer(socket: socket) { _ in .failure("second") }.start() }
    let encoded = String(
      decoding: try ControlChannel.encode(
        ControlRequest(command: "stop", arguments: ["discard": true])), as: UTF8.self)
    precondition(encoded == "{\"arguments\":{\"discard\":true},\"command\":\"stop\"}\n")
    let decoded = try ControlChannel.decode(
      ControlResponse.self, from: Data(#"{"ok":true,"meeting_id":"x","message":"Stopped"}"#.utf8))
    precondition(decoded == ControlResponse(ok: true, message: "Stopped", meetingId: "x"))
  }

  static func testWait(_ library: MeetingLibrary, root: URL) throws {
    var bridge = AgentBridge(library: library)
    bridge.socket = root.appendingPathComponent("absent.sock")
    bridge.configFile = root.appendingPathComponent("config.json")
    guard case .ready(let ready) = try bridge.waitForTranscript(meetingId: "design", timeout: 1)
    else { preconditionFailure("A complete meeting is ready at once") }
    precondition(ready.id == "20261105T151700Z")
    var failed = MeetingRecord(id: "20261105T170000Z", startedAt: Date(), status: .failed)
    failed.error = "Disk full"
    try library.save(failed)
    expectError(
      { _ = try bridge.waitForTranscript(meetingId: "20261105T170000Z", timeout: 1) },
      message: { $0.contains("needs attention: Disk full") })
    expectError(
      { _ = try bridge.waitForTranscript(meetingId: "20261105T160000Z", timeout: 1) },
      message: { $0.contains("not running") })
    expectError(
      { _ = try bridge.waitForTranscript(meetingId: nil, timeout: 1) },
      message: { $0.contains("not running") })
    expectError(
      { _ = try bridge.waitForTranscript(meetingId: "1999", timeout: 1) },
      message: { $0.contains("No meeting matches") })
    let offline = bridge.status()
    precondition(!offline.running && offline.attention.map(\.meetingId) == ["20261105T170000Z"])
    precondition(offline.queue.map(\.meetingId) == ["20261105T160000Z"])
    precondition(offline.attention[0].canRetry == false)
    let summary = StatusSnapshot.offline(library: library, configFile: bridge.configFile).summary
    precondition(summary.contains("1 meeting needs attention"), summary)
    try FileManager.default.removeItem(at: library.recordURL(for: "20261105T170000Z"))
  }

  static func testCommandLine() throws {
    let arguments = try CommandLineInterface.Arguments(
      ["20261105T151700Z", "--since", "7d", "--json", "--format=text", "--", "--title"])
    precondition(arguments.positional == ["20261105T151700Z", "--title"])
    precondition(arguments.options == ["since": "7d", "format": "text"])
    precondition(arguments.flags == ["json"])
    expectError { _ = try CommandLineInterface.Arguments(["--limit"]) }
    for option in [["--source", "us.zoom.xos"], ["--source=auto"], ["--source"]] {
      expectError { _ = try CommandLineInterface.Arguments(option) }
    }
    precondition(!CommandLineInterface.commands.contains("recording-sources"))
    expectError { _ = try CommandLineInterface.Arguments(["--limit", "0"]).int("limit") }
    precondition(CommandLineInterface.duration(65.4) == "1:05")
    precondition(CommandLineInterface.duration(3_725) == "1:02:05")
    let setup = AgentSetup()
    precondition(setup.serverCommand == "meeting-notes mcp")
    precondition(
      setup.shellCommands.contains("claude mcp add --scope user meeting-notes -- meeting-notes mcp")
    )
    precondition(AgentSetup.quoted("it's") == "'it'\\''s'")
    testAgentRemoval(setup)
    testOnboardingPages()
    try testCommandLineShim()
  }

  static func testAgentRemoval(_ setup: AgentSetup) {
    let agents = Dictionary(uniqueKeysWithValues: setup.agents.map { ($0.id, $0) })
    precondition(agents["codex"]?.removeCommand == "codex mcp remove meeting-notes")
    precondition(agents["claude"]?.removeCommand == "claude mcp remove --scope user meeting-notes")
    precondition(agents["pi"]?.removeCommand == "pi mcp remove meeting-notes")
    for agent in setup.agents {
      precondition(
        agent.command.hasPrefix("\(agent.tool) mcp add ")
          && agent.removeCommand.hasPrefix("\(agent.tool) mcp remove "),
        "\(agent.name) adds and removes with its own tool")
      precondition(
        agent.command.hasSuffix(setup.serverCommand),
        "One-click connect uses the installed meeting-notes command")
      precondition(
        !agent.check.contains("MeetingNotes"),
        "Detection matches the server name, so a server added with \(AgentSetup.manualServerCommand) counts as connected"
      )
    }
    precondition(AgentSetup.manualServerCommand == "meeting-notes mcp")

    let connectError = AgentConnection.failed("codex: not allowed")
    precondition(connectError.updated(by: .notConnected) == connectError)
    precondition(connectError.updated(by: .connected) == .connected)
    precondition(connectError.updated(by: .notInstalled) == .notInstalled)
    let removeError = AgentConnection.removeFailed("pi: read-only file")
    precondition(removeError.updated(by: .connected) == removeError)
    precondition(removeError.updated(by: .notConnected) == .notConnected)
    precondition(AgentConnection.connected.updated(by: .notConnected) == .notConnected)
    precondition(AgentConnection.checking.updated(by: .connected) == .connected)
    precondition(
      connectError.isFailure && removeError.isFailure && !AgentConnection.connected.isFailure)
  }

  static func testOnboardingPages() {
    func next(_ page: OnboardingState.Page, completed: Bool = false, agent: Bool = true)
      -> OnboardingState.Page?
    {
      OnboardingState.page(after: page, permissionsOnly: completed, hasInstalledAgent: agent)
    }
    precondition(next(.permissions) == .preferences)
    precondition(next(.preferences) == .agents)
    precondition(next(.agents) == .done)
    precondition(next(.done) == nil)
    precondition(next(.preferences, agent: false) == .done, "No agents step without an agent")
    precondition(
      next(.permissions, completed: true) == nil,
      "After the first setup, missing permissions show only the permissions page")
    precondition(OnboardingState.page(before: .done, hasInstalledAgent: false) == .preferences)
    precondition(OnboardingState.page(before: .done, hasInstalledAgent: true) == .agents)
    precondition(OnboardingState.page(before: .permissions, hasInstalledAgent: true) == nil)
  }

  static func testCommandLineShim() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(
      "meeting-notes-shim-\(UUID().uuidString)/bin")
    defer { try? manager.removeItem(at: directory.deletingLastPathComponent()) }
    let shim = directory.appendingPathComponent("meeting-notes")
    func contents() -> String { (try? String(contentsOf: shim, encoding: .utf8)) ?? "" }
    let old = "/Applications/Meeting Notes.app/Contents/MacOS/MeetingNotes"
    let installed = try CommandLineShim.install(executable: old, in: directory)
    precondition(installed && contents() == "#!/bin/sh\nexec '\(old)' \"$@\"\n")
    let mode = try manager.attributesOfItem(atPath: shim.path)[.posixPermissions] as? Int
    precondition(mode == 0o755)
    let again = try CommandLineShim.install(executable: old, in: directory)
    precondition(!again, "An unchanged shim is not rewritten")
    let moved = "/Users/me/Applications/Meeting Notes.app/Contents/MacOS/MeetingNotes"
    let updated = try CommandLineShim.install(executable: moved, in: directory)
    precondition(updated && contents().contains(moved))
    try "#!/bin/sh\necho mine\n".write(to: shim, atomically: true, encoding: .utf8)
    expectError { _ = try CommandLineShim.install(executable: old, in: directory) }
    precondition(contents() == "#!/bin/sh\necho mine\n", "A foreign file stays")
  }

  static func testMCP(_ library: MeetingLibrary, root: URL) throws {
    var bridge = AgentBridge(library: library)
    bridge.configFile = root.appendingPathComponent("config.json")
    bridge.socket = root.appendingPathComponent("absent.sock")
    bridge.allowsAppLaunch = false
    let server = MCPServer(bridge: bridge)
    func call(_ method: String, _ params: JSONValue = [:]) -> JSONValue {
      let request: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params,
      ]
      return server.handle(
        line: String(decoding: try! JSONCoding.encoder().encode(request), as: UTF8.self))!
    }
    let initialized = call("initialize", ["protocolVersion": "2025-06-18"])
    precondition(initialized["result"]?["protocolVersion"] == "2025-06-18")
    precondition(initialized["result"]?["capabilities"]?["tools"] != nil)
    precondition(
      call("initialize", ["protocolVersion": "unknown"])["result"]?["protocolVersion"]
        == "2025-06-18")
    precondition(
      server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    precondition(server.handle(line: "{not json")?["error"]?["code"] == -32700)
    precondition(call("nope/method")["error"]?["code"] == -32601)
    precondition(call("ping")["result"] == [:])
    guard case .array(let tools) = call("tools/list")["result"]?["tools"] else {
      preconditionFailure()
    }
    precondition(tools.count == 12)
    precondition(tools.first?["name"] == "get_meeting")
    precondition(tools.first?["inputSchema"]?["required"] == nil)
    for tool in tools { precondition(tool["inputSchema"]?["additionalProperties"] == false) }
    precondition(call("tools/call", ["name": "missing"])["error"]?["code"] == -32602)
    for name in ["start_recording", "stop_recording"] {
      for bad: JSONValue in [.array(["invalid"]), .string("bad"), .null, .number(3)] {
        precondition(
          call("tools/call", ["name": .string(name), "arguments": bad])["error"]?["code"] == -32602)
      }
    }
    let pending = call("tools/call", ["name": "get_meeting", "arguments": [:]])
    guard case .array(let content) = pending["result"]?["content"] else { preconditionFailure() }
    let text = content.first?["text"]?.stringValue ?? ""
    precondition(text.contains("20261105T160000Z") && text.contains("not ready"), text)
    precondition(!text.contains("The budget is fine"), "Must never substitute an older transcript")
    precondition(pending["result"]?["structuredContent"] == nil)
  }

  private static func expectError(
    _ body: () throws -> Void, line: Int = #line, message: (String) -> Bool = { _ in true }
  ) {
    do {
      try body()
      preconditionFailure("Line \(line): expected an error")
    } catch {
      precondition(
        message(error.localizedDescription), "Line \(line): \(error.localizedDescription)")
    }
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, line: Int = #line) throws
  {
    guard try condition() else { preconditionFailure("Line \(line): expectation failed") }
  }
}

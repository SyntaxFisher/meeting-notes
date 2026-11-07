import Foundation

/// Runs the real MCP surface against an explicitly marked, temporary fixture library.
enum AgentFixture {
  static func run(root: URL) throws {
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    let temporaryRoots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
      .map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
    guard temporaryRoots.contains(where: { root.path.hasPrefix($0) }),
      let marker = try? String(
        contentsOf: root.appendingPathComponent(".agent-fixture"), encoding: .utf8),
      marker == "meeting-notes-agent-fixture\n"
    else { throw MeetingError("Agent fixtures must use a marked temporary directory.") }

    let configFile = root.appendingPathComponent("config.json")
    let library = fixtureLibrary(root)
    library.timeZone = TimeZone(identifier: "Europe/Berlin")!
    var bridge = AgentBridge(library: library)
    bridge.configFile = configFile
    bridge.socket = root.appendingPathComponent("control.sock")
    bridge.allowsAppLaunch = false
    let control = FixtureControl(root: root)
    var controlServer: ControlServer?
    if FileManager.default.fileExists(
      atPath: root.appendingPathComponent("fixture-controls.json").path)
    {
      let endpoint = ControlServer(socket: bridge.socket) { request in control.handle(request) }
      try endpoint.start()
      controlServer = endpoint
    }
    defer { controlServer?.stop() }
    let server = MCPServer(bridge: bridge)
    let traceURL = root.appendingPathComponent("mcp-trace.jsonl")
    if !FileManager.default.fileExists(atPath: traceURL.path) {
      FileManager.default.createFile(
        atPath: traceURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let trace = try FileHandle(forWritingTo: traceURL)
    defer { try? trace.close() }
    try trace.seekToEnd()

    while let line = readLine(strippingNewline: true) {
      guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
      if request?["method"]?.stringValue == "tools/call" { try control.advance() }
      let response = server.handle(line: line)
      let event: JSONValue = [
        "request": request ?? .string(line), "response": response ?? .null,
      ]
      var data = try JSONCoding.encoder().encode(event)
      data.append(0x0A)
      try trace.write(contentsOf: data)
      if request?["method"]?.stringValue == "tools/call",
        let tool = request?["params"]?["name"]?.stringValue,
        ["get_meeting", "search_meetings"].contains(tool),
        let injection = try? Data(contentsOf: root.appendingPathComponent("inject-stale.json")),
        let change = try? JSONDecoder().decode(JSONValue.self, from: injection),
        let id = change["meeting_id"]?.stringValue,
        let segment = change["segment_id"]?.stringValue,
        let replacement = change["text"]?.stringValue
      {
        try FileManager.default.removeItem(at: root.appendingPathComponent("inject-stale.json"))
        let record = try library.load(id)
        _ = try library.editTranscript(
          id, changes: [MeetingTextChange(segmentID: segment, text: replacement)],
          expectedRevision: record.revision)
      }
      if let response { server.send(response) }
    }
  }

  static func fixtureLibrary(_ root: URL) -> MeetingLibrary {
    let library = MeetingLibrary(root: root)
    library.trash = { file in
      let trash = root.appendingPathComponent(".fixture-trash", isDirectory: true)
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      try FileManager.default.moveItem(
        at: file, to: trash.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
      )
    }
    return library
  }
}

/// Simulates the app's control boundary without capture devices or the user's library.
private final class FixtureControl: @unchecked Sendable {
  private let root: URL
  private let lock = NSLock()

  init(root: URL) { self.root = root }

  private func object(_ name: String) -> [String: JSONValue] {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
      let json = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return [:] }
    return json.objectValue ?? [:]
  }

  private func writeState(_ value: [String: JSONValue]) throws {
    try JSONCoding.encoder().encode(JSONValue.object(value)).write(
      to: root.appendingPathComponent("fixture-state.json"), options: .atomic)
  }

  func advance() throws {
    lock.lock()
    defer { lock.unlock() }
    try tick()
  }

  private func tick() throws {
    let config = object("fixture-controls.json")
    guard !config.isEmpty else { return }
    var state = object("fixture-state.json")
    var scheduled = state["scheduled"]?.objectValue ?? [:]
    if state["began"] == nil {
      state["began"] = .number(Date().timeIntervalSince1970)
      if case .array(let transitions) = config["transitions"] {
        for transition in transitions {
          if let id = transition["meeting_id"]?.stringValue,
            let delay = transition["delay"]?.doubleValue
          {
            scheduled[id] = .number(Date().timeIntervalSince1970 + delay)
          }
        }
      }
    }
    let library = AgentFixture.fixtureLibrary(root)
    for (id, deadline) in scheduled {
      guard let deadline = deadline.doubleValue, Date().timeIntervalSince1970 >= deadline else {
        continue
      }
      defer { scheduled[id] = nil }
      guard var record = try? library.load(id), record.status.isInProgress else { continue }
      let outcome = config["outcome"]?.stringValue ?? "complete"
      if outcome == "discard" {
        _ = try library.moveToTrash(id)
      } else if outcome == "failed" {
        record.status = .failed
        record.error = "The transcription engine could not read this recording."
        record.failedAt = Date()
        try library.save(record)
      } else {
        record.status = .complete
        record.stage = nil
        record.progress = nil
        record.error = nil
        record.failedAt = nil
        record.endedAt = Date()
        record.durationSeconds = max(record.durationSeconds ?? 0, 10)
        record.segments = [
          MeetingSegment(
            start: 0, end: 10, speaker: "Speaker 1",
            text: config["completion_text"]?.stringValue
              ?? "Wir veröffentlichen den PDF-Export am Dienstag. Mira prüft vorher die Anleitung.")
        ]
        record.speakers = MeetingRecord.speakers(for: record.segments)
        record.transcriptFile = id + ".txt"
        try library.save(record)
        try Data(MeetingLibrary.transcriptText(record).utf8).write(
          to: library.transcripts.appendingPathComponent(id + ".txt"), options: .atomic)
      }
    }
    state["scheduled"] = .object(scheduled)
    try writeState(state)
  }

  private func schedule(_ id: String, delay: Double) throws {
    var state = object("fixture-state.json")
    var scheduled = state["scheduled"]?.objectValue ?? [:]
    scheduled[id] = .number(Date().timeIntervalSince1970 + delay)
    state["scheduled"] = .object(scheduled)
    try writeState(state)
  }

  private func snapshot(_ library: MeetingLibrary) -> StatusSnapshot {
    let config = object("fixture-controls.json")
    var status = StatusSnapshot.offline(
      library: library, configFile: root.appendingPathComponent("config.json"))
    let records = library.meetings()
    let recording = records.first { $0.status == .recording }
    status.running = true
    status.canStartRecording = recording == nil && config["blocked_reason"] == nil
    status.startBlockedReason = config["blocked_reason"]?.stringValue
    if let recording {
      status.recording = .init(
        meetingId: recording.id, title: recording.title, startedAt: recording.startedAt,
        elapsedSeconds: max(0, Date().timeIntervalSince(recording.startedAt)),
        trigger: .manual, source: .deviceAudio, mutedInTeams: false)
    }
    status.queue.removeAll { $0.status == .recording }
    if case .array(let missing) = config["missing_permissions"] {
      status.missingPermissions = missing.compactMap(\.stringValue)
    }
    status.summary =
      recording != nil ? "Recording." : status.queue.isEmpty ? "Ready." : "Transcribing."
    return status
  }

  func handle(_ request: ControlRequest) -> ControlResponse {
    lock.lock()
    defer { lock.unlock() }
    let library = AgentFixture.fixtureLibrary(root)
    let config = object("fixture-controls.json")
    do {
      try tick()
      var resultID: String?
      var message: String?
      switch request.command {
      case "ping", "status": break
      case "open_meeting":
        guard let text = request.arguments["url"]?.stringValue, let url = URL(string: text),
          let link = MeetingLink(url: url)
        else { throw MeetingError("Invalid meeting URL.") }
        try link.validate(in: library.load(link.meetingID))
        var state = object("fixture-state.json")
        state["opened_url"] = .string(link.string)
        try writeState(state)
        resultID = link.meetingID
        message = "Opened in Meeting Notes."
      case "start":
        guard !library.meetings().contains(where: { $0.status == .recording }) else {
          throw MeetingError("A recording is already running.")
        }
        if let reason = config["blocked_reason"]?.stringValue { throw MeetingError(reason) }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        let base = formatter.string(from: now)
        var id = base
        var suffix = 2
        while library.meetings().contains(where: { $0.id == id }) {
          id = base + "-\(suffix)"
          suffix += 1
        }
        var record = MeetingRecord(
          id: id, title: request.arguments["title"]?.stringValue, startedAt: now,
          status: .recording, source: .deviceAudio, trigger: .manual)
        record.audioFile = id + ".m4a"
        try library.save(record)
        try Data("Synthetic audio fixture".utf8).write(
          to: library.audios.appendingPathComponent(id + ".m4a"))
        resultID = id
        message = "Recording started."
      case "stop":
        guard var record = library.meetings().first(where: { $0.status == .recording }) else {
          throw MeetingError("No recording is running.")
        }
        resultID = record.id
        if request.arguments["discard"]?.boolValue == true {
          _ = try library.moveToTrash(record.id)
          message = "Moved to Trash."
        } else {
          record.status = .transcribing
          record.endedAt = Date()
          record.durationSeconds = 10
          try library.save(record)
          try schedule(record.id, delay: config["stop_delay"]?.doubleValue ?? 2)
          message = "Recording stopped; transcription is processing."
        }
      case "retry":
        let candidates = library.meetings().filter(\.status.needsAttention)
        let id: String
        if let reference = request.arguments["meeting_id"]?.stringValue {
          id = try library.resolve(reference)
        } else if candidates.count == 1 {
          id = candidates[0].id
        } else {
          throw MeetingError("Specify the meeting to retry.")
        }
        var record = try library.load(id)
        guard record.status.needsAttention, library.audioURL(of: record) != nil else {
          throw MeetingError("This meeting has no recording available to retry.")
        }
        record.status = .transcribing
        record.error = nil
        try library.save(record)
        try schedule(id, delay: config["stop_delay"]?.doubleValue ?? 2)
        resultID = id
        message = "Queued for transcription."
      case "delete", "discard":
        guard let reference = request.arguments["meeting_id"]?.stringValue else {
          throw MeetingError("Specify the meeting to delete.")
        }
        let id = try library.resolve(reference)
        _ = try library.moveToTrash(id)
        resultID = id
        message = "Moved to Trash."
      default: throw MeetingError("Unsupported fixture control command.")
      }
      return ControlResponse(
        ok: true, message: message, meetingId: resultID, status: snapshot(library))
    } catch {
      return .failure(error.localizedDescription, status: snapshot(library))
    }
  }
}

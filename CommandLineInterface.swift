import Foundation

/// `MeetingNotes <command>`: a scriptable front end to the app. Read-only commands work from the
/// files alone; actions talk to the running app and launch it when needed.
struct CommandLineInterface {
  static let commands: Set<String> = [
    "help", "status", "list", "show", "search", "start", "stop", "discard", "retry", "delete",
    "wait", "set-title", "rename-speaker", "settings", "mcp", "agent-setup",
    "transcribe", "teams-participants", "check-teams-mute",
    "edit-text", "merge-speakers",
  ]

  static let usage = """
    Usage: MeetingNotes <command> [options]

    Meetings (read files directly; work without the app running):
      list [--since D] [--until D] [--query Q] [--status S] [--limit N]
                                      List meetings, newest first. S is a status such as
                                      complete, queued or failed (comma-separated).
      show <id> [--format markdown|text|json]
                                      Print a meeting's metadata and transcript.
      search <query> [--since D] [--until D] [--meeting ID] [--limit N]
                                      Find transcript passages; prints timestamps.
      rename-speaker <id> <label> <name>
                                      Name a speaker, e.g. rename-speaker latest 2 "Ada".
                                      An empty name clears it.
      edit-text <id> <segment-id> <text> --revision N
                                      Correct one passage and overwrite the transcript.
      merge-speakers <id> <keep> <merge...> --revision N [--name N]
                                      Combine duplicate speaker labels.
      set-title [--meeting ID] <title>
                                      Retitle a meeting, or the recording in progress
                                      when no --meeting is given.

    Recording and the transcription queue (talk to the app; launch it if needed):
      status                          What is recording, queued, transcribing or failed.
      start [--title T]               Record the microphone and Teams during a Teams
                                      meeting, otherwise all device audio. Earlier meetings
                                      can continue transcribing.
      stop [--discard]                Stop and queue for transcription, or stop and move
                                      the recording to the Trash.
      retry [<id>]                    Transcribe a failed or interrupted meeting again.
      discard [<id>]                  Move an unfinished meeting to the Trash, cancelling
                                      its transcription. Without an id, only when exactly
                                      one meeting needs attention (same for retry).
      delete <id>                     Move a meeting to the Trash, stopping any active work.
      wait [<id>] [--timeout S]       Block until that meeting's transcript is ready, or
                                      without an id until the next transcript is ready;
                                      print its id and path. Default timeout 3600 s.
      settings [auto-record on|off] [mirror-mute on|off] [sounds on|off] [local-name NAME|default]
               [recordings-limit SIZE]
                                      Show or change settings in config.json. SIZE is
                                      bytes or a number with KB, MB, GB or TB (1 GB =
                                      10^9 bytes). Lowering a limit deletes the oldest
                                      meetings above it right away.

    Agents:
      mcp                             Serve the Model Context Protocol on stdin/stdout.
      agent-setup [--connect codex|claude]
                                      Show which agents are connected and the commands that
                                      add the MCP server; --connect runs one of them.

    Diagnostics:
      transcribe <audio> <out.txt> [--capture DIR] [--name N] [--title T]
                                      Transcribe a recording like the app does; writes
                                      <out.txt> and its record <out>.json, never overwriting.
      teams-participants              Print the current Teams meeting's participants.
      check-teams-mute                Print the detected Teams mute state.

    Meeting ids are the UTC start time that names every file of a meeting, e.g.
    20261105T141700Z. A unique id prefix or title fragment also works, and `latest` means the
    newest transcript. Edit-text and merge-speakers require the exact meeting id.
    Dates: 2026-11-05, an ISO timestamp, today, yesterday, or an age such
    as 7d or 12h. Add --json to any command for machine-readable output.
    Exit codes: 0 success, 1 error, 2 usage error, 3 wait timed out.
    """

  struct UsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = [
      "since", "until", "query", "limit", "format", "meeting", "timeout", "title", "dir",
      "status", "capture", "name", "connect", "revision", "edit",
      "offset", "detail-offset", "max-chars",
    ]

    init(_ raw: [String]) throws {
      var index = 0
      while index < raw.count {
        let argument = raw[index]
        if argument == "--" {
          positional += raw[(index + 1)...]
          break
        }
        if argument.hasPrefix("--") {
          var name = String(argument.dropFirst(2))
          if name == "source" || name.hasPrefix("source=") {
            throw UsageError(message: "Recording sources are selected automatically.")
          }
          if let equals = name.firstIndex(of: "=") {
            options[String(name[..<equals])] = String(name[name.index(after: equals)...])
            index += 1
            continue
          }
          if Self.valueOptions.contains(name) {
            guard index + 1 < raw.count else {
              throw UsageError(message: "--\(name) needs a value.")
            }
            options[name] = raw[index + 1]
            index += 2
            continue
          }
          name = name.lowercased()
          flags.insert(name)
        } else {
          positional.append(argument)
        }
        index += 1
      }
    }

    func date(_ name: String) throws -> Date? { try options[name].map { try DateFilter.parse($0) } }
    func statuses() throws -> Set<MeetingStatus>? {
      guard let text = options["status"] else { return nil }
      var result: Set<MeetingStatus> = []
      for name in text.split(separator: ",") {
        guard let status = MeetingStatus(rawValue: name.trimmingCharacters(in: .whitespaces))
        else {
          throw UsageError(
            message: "Unknown status \"\(name)\". Use "
              + MeetingStatus.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        result.insert(status)
      }
      return result
    }
    func int(_ name: String, minimum: Int = 1) throws -> Int? {
      guard let text = options[name] else { return nil }
      guard let value = Int(text), value >= minimum else {
        throw UsageError(message: "--\(name) needs an integer of at least \(minimum).")
      }
      return value
    }
  }

  var bridge = AgentBridge()
  var json = false

  static func run(_ raw: [String]) -> Int32 {
    var cli = CommandLineInterface()
    let command = raw.first ?? "help"
    do {
      let arguments = try Arguments(Array(raw.dropFirst()))
      cli.json = arguments.flags.contains("json")
      return try cli.execute(command, arguments)
    } catch let error as UsageError {
      cli.fail(error.message)
      if !cli.json {
        FileHandle.standardError.write(Data("Run `MeetingNotes help` for usage.\n".utf8))
      }
      return 2
    } catch {
      cli.fail(error.localizedDescription)
      return 1
    }
  }

  private func fail(_ message: String) {
    if json {
      emitJSON(["error": .string(message)] as JSONValue)
    } else {
      FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
  }

  private func emitJSON<T: Encodable>(_ value: T) {
    let data = (try? JSONCoding.encoder(pretty: true).encode(value)) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
  }

  private func execute(_ command: String, _ arguments: Arguments) throws -> Int32 {
    let library = bridge.library
    if !["help", "settings", "agent-setup", "teams-participants", "check-teams-mute"].contains(
      command)
    {
      LibraryReader.migrateFiles(library.root)
    }
    switch command {
    case "help":
      print(Self.usage)
    case "status":
      let status = bridge.status()
      json ? emitJSON(status) : print(Self.describe(status))
    case "list":
      let records = library.list(
        since: try arguments.date("since"), until: try arguments.date("until"),
        queries: (arguments.options["query"] ?? arguments.positional.first).map { [$0] } ?? [],
        status: try arguments.statuses(), limit: try arguments.int("limit"))
      let summaries = records.map(library.summary(of:))
      json ? emitJSON(summaries) : print(Self.table(summaries))
    case "show":
      guard let reference = arguments.positional.first else {
        throw UsageError(message: "show needs a meeting id.")
      }
      let record = try library.load(library.resolve(reference))
      if json {
        emitJSON(try MeetingLibrary.json(record))
      } else {
        let name = arguments.options["format"] ?? "markdown"
        guard let format = TranscriptFormat(rawValue: name) else {
          throw UsageError(message: "--format must be markdown, text or json.")
        }
        print(try library.render(record, as: format))
      }
    case "search":
      let query = arguments.options["query"] ?? arguments.positional.joined(separator: " ")
      guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw UsageError(message: "search needs a query.")
      }
      let hits = library.search(
        [query], since: try arguments.date("since"), until: try arguments.date("until"),
        meeting: try arguments.options["meeting"].map(library.resolve),
        limit: try arguments.int("limit") ?? 20)
      if json {
        emitJSON(hits)
      } else if hits.isEmpty {
        print("No matches for \"\(query)\".")
      } else {
        var lastMeeting: String?
        for hit in hits {
          if hit.meetingId != lastMeeting {
            if lastMeeting != nil { print("") }
            print(hit.meetingId)
            lastMeeting = hit.meetingId
          }
          print("  [\(hit.timestamp)] \(hit.speaker): \(hit.text)")
        }
      }
    case "edit-text", "merge-speakers":
      guard let reference = arguments.positional.first,
        let text = arguments.options["revision"], let revision = Int(text), revision >= 0
      else { throw UsageError(message: "Pass a meeting id and --revision from show.") }
      let id = try MeetingAgentView.exactID(["meeting_id": .string(reference)], library: library)
      let result: MeetingEditResult
      if command == "edit-text" {
        guard arguments.positional.count >= 3 else {
          throw UsageError(
            message: "edit-text needs a meeting id, segment id and replacement text.")
        }
        result = try library.editTranscript(
          id,
          changes: [
            MeetingTextChange(
              segmentID: arguments.positional[1],
              text: arguments.positional.dropFirst(2).joined(separator: " "))
          ],
          expectedRevision: revision)
      } else {
        guard arguments.positional.count >= 3 else {
          throw UsageError(
            message: "merge-speakers needs a meeting id, survivor and labels to merge.")
        }
        result = try library.mergeSpeakers(
          id, keep: arguments.positional[1], merge: Array(arguments.positional.dropFirst(2)),
          name: arguments.options["name"], expectedRevision: revision)
      }
      if json {
        emitJSON(MeetingAgentView.mutation(result))
      } else {
        print(
          !result.changed
            ? "No change needed." : "Changed \(id); revision \(result.record.revision).")
      }
    case "start":
      var options: [String: JSONValue] = [:]
      if let title = arguments.options["title"] ?? arguments.positional.first {
        options["title"] = .string(title)
      }
      return try action("start", options)
    case "stop":
      return try action("stop", arguments.flags.contains("discard") ? ["discard": true] : [:])
    case "discard", "retry":
      return try action(
        command, arguments.positional.first.map { ["meeting_id": .string($0)] } ?? [:])
    case "delete":
      guard let reference = arguments.positional.first else {
        throw UsageError(message: "delete needs a meeting id.")
      }
      return try action("delete", ["meeting_id": .string(reference)])
    case "wait":
      let timeout = Double(try arguments.int("timeout") ?? 3600)
      let outcome = try bridge.waitForTranscript(
        meetingId: arguments.positional.first, timeout: timeout,
        progress: { status in
          if !json { FileHandle.standardError.write(Data("\(status.summary)\n".utf8)) }
        })
      switch outcome {
      case .ready(let record):
        let summary = library.summary(of: record)
        if json {
          emitJSON(summary)
        } else {
          print(record.id)
          if let path = summary.transcriptPath { print(path) }
        }
      case .timedOut(let status):
        if json {
          emitJSON(["error": "Timed out.", "status": try JSONValue.from(status)] as JSONValue)
        } else {
          FileHandle.standardError.write(
            Data("Timed out after \(Int(timeout)) s. \(status.summary)\n".utf8))
        }
        return 3
      }
    case "set-title":
      let title = arguments.positional.joined(separator: " ")
      guard !title.isEmpty else { throw UsageError(message: "set-title needs a title.") }
      if let reference = arguments.options["meeting"], !bridge.isServing {
        let record = try library.setTitle(library.resolve(reference), title: title)
        json
          ? emitJSON(library.summary(of: record))
          : print("Title of \(record.id): \(record.displayTitle)")
      } else {
        var options: [String: JSONValue] = ["title": .string(title)]
        if let reference = arguments.options["meeting"] {
          options["meeting_id"] = .string(reference)
        }
        return try action("set_title", options)
      }
    case "rename-speaker":
      guard arguments.positional.count >= 2 else {
        throw UsageError(message: "rename-speaker needs a meeting id, a speaker label and a name.")
      }
      let name = arguments.positional.dropFirst(2).joined(separator: " ")
      let record = try library.renameSpeakers(
        library.resolve(arguments.positional[0]), names: [arguments.positional[1]: name])
      if json {
        emitJSON(library.summary(of: record))
      } else {
        for speaker in record.speakers {
          print("\(speaker.label): \(speaker.name ?? "(unnamed)")")
        }
      }
    case "settings":
      var change = SettingsChange()
      var pairs = arguments.positional[...]
      while let key = pairs.popFirst() {
        guard let value = pairs.popFirst() else {
          throw UsageError(message: "\(key) needs a value.")
        }
        func flag() throws -> Bool {
          guard ["on", "off", "true", "false", "yes", "no"].contains(value.lowercased()),
            let enabled = JSONValue.string(value).boolValue
          else { throw UsageError(message: "Use settings \(key) on|off.") }
          return enabled
        }
        switch key {
        case "auto-record": change.autoRecordTeamsMeetings = try flag()
        case "mirror-mute": change.mirrorTeamsMute = try flag()
        case "sounds": change.playSounds = try flag()
        case "local-name":
          change.localSpeakerName = .some(value.lowercased() == "default" ? nil : value)
        case "recordings-limit":
          guard let bytes = Self.byteCount(value) else {
            throw UsageError(message: "Use settings \(key) SIZE, for example 20GB.")
          }
          change.audioBytes = bytes
        default:
          throw UsageError(
            message:
              "Unknown setting \"\(key)\". Use auto-record, mirror-mute, sounds, local-name or recordings-limit."
          )
        }
      }
      if !change.isEmpty {
        let message = try bridge.updateSettings(change)
        if !json { print(message) }
      }
      let settings = bridge.status().settings
      if json {
        emitJSON(settings)
      } else {
        print("auto-record: \(settings.autoRecordTeamsMeetings ? "on" : "off")")
        print("mirror-mute: \(settings.mirrorTeamsMute ? "on" : "off")")
        print("sounds: \(settings.playSounds ? "on" : "off")")
        print("local-name: \(settings.localSpeakerName ?? "default (Teams name, else macOS name)")")
        print("meetings-folder: \(settings.meetingsRoot)")
        print("recordings-limit: \(Self.size(settings.retentionAudioBytes))")
        print("config: \(settings.configPath)")
        if let error = settings.configError { print("config error: \(error)") }
      }
    case "teams-participants":
      let started = Date()
      guard let sightings = TeamsParticipantReader.read() else {
        throw MeetingError("No single Teams meeting window could be read.")
      }
      var roster = ParticipantRoster()
      roster.observe(sightings, at: 0)
      emitJSON(roster)
      if !json {
        FileHandle.standardError.write(
          Data(String(format: "Read in %.2f s\n", Date().timeIntervalSince(started)).utf8))
      }
    case "check-teams-mute":
      let reading = TeamsMuteReader().read()
      let muted: String
      switch reading.state {
      case .muted: muted = "muted"
      case .unmuted: muted = "unmuted"
      case .unavailable(let reason): muted = "unavailable (\(reason.message))"
      }
      if json {
        emitJSON(
          [
            "meeting_title": reading.meetingTitle.map(JSONValue.string) ?? .null,
            "mute": .string(muted),
          ]
            as JSONValue)
      } else {
        print("Teams meeting title: \(reading.meetingTitle ?? "none")")
        print("Teams mic: \(muted)")
      }
    case "mcp":
      MCPServer(bridge: bridge).run()
    case "agent-setup":
      let setup = AgentSetup()
      if let id = arguments.options["connect"] {
        guard let agent = setup.agents.first(where: { $0.id == id }) else {
          throw UsageError(
            message: "--connect takes " + setup.agents.map(\.id).joined(separator: ", ") + ".")
        }
        let state = AgentConnector.connect(agent)
        guard state == .connected else {
          if case .failed(let message) = state { throw MeetingError(message) }
          throw MeetingError("\(agent.name) is not connected.")
        }
        json
          ? emitJSON(["agent": .string(agent.id), "connected": true] as JSONValue)
          : print("Connected Meeting Notes to \(agent.name).")
        return 0
      }
      if json {
        var agents: [JSONValue] = []
        for agent in setup.agents {
          let state = AgentConnector.state(of: agent)
          agents.append([
            "id": .string(agent.id), "name": .string(agent.name),
            "command": .string(agent.command), "connected": .bool(state == .connected),
            "installed": .bool(state != .notInstalled),
          ])
        }
        emitJSON(["command": .string(setup.serverCommand), "agents": .array(agents)] as JSONValue)
      } else {
        for agent in setup.agents {
          let state = AgentConnector.state(of: agent)
          let label =
            state == .connected
            ? "connected" : state == .notInstalled ? "not installed" : "not connected"
          print("# \(agent.name) (\(label))\n\(agent.command)")
        }
      }
    default:
      throw UsageError(message: "Unknown command \"\(command)\".")
    }
    return 0
  }

  private func action(_ command: String, _ arguments: [String: JSONValue] = [:]) throws -> Int32 {
    let response = try bridge.perform(command, arguments)
    if json {
      emitJSON(response)
    } else if response.ok {
      print(response.message ?? "OK")
      if let id = response.meetingId { print("Meeting: \(id)") }
    } else {
      FileHandle.standardError.write(Data("Error: \(response.message ?? "Failed.")\n".utf8))
    }
    return response.ok ? 0 : 1
  }

  static var executablePath: String {
    Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
      ?? "/Applications/Meeting Notes.app/Contents/MacOS/MeetingNotes"
  }

  // MARK: Human-readable formatting

  /// Bytes from "10000000000", "20GB", "1.5 TB" or "500mb", in decimal units; nil when the
  /// text is not a positive size.
  static func byteCount(_ text: String) -> Int64? {
    let units: [String: Double] = ["": 1, "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
    let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
    let number = trimmed.prefix { $0.isNumber || $0 == "." }
    let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
    guard let value = Double(number), let factor = units[unit],
      let bytes = Int64(exactly: (value * factor).rounded()), bytes >= 1
    else { return nil }
    return bytes
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func duration(_ seconds: Double?) -> String {
    guard let seconds else { return "-" }
    let total = Int(seconds.rounded())
    return total >= 3600
      ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
      : String(format: "%d:%02d", total / 60, total % 60)
  }

  static func localTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  static func table(_ meetings: [MeetingSummary]) -> String {
    guard !meetings.isEmpty else { return "No meetings found." }
    var lines = ["STARTED           LENGTH   SPEAKERS  STATUS        MEETING"]
    for meeting in meetings {
      let status = meeting.status.rawValue
      lines.append(
        localTime(meeting.startedAt).padding(toLength: 18, withPad: " ", startingAt: 0)
          + duration(meeting.durationSeconds).padding(toLength: 9, withPad: " ", startingAt: 0)
          + String(meeting.speakers.count).padding(toLength: 10, withPad: " ", startingAt: 0)
          + status.padding(toLength: 14, withPad: " ", startingAt: 0)
          + (meeting.title.map { "\(meeting.id) \($0)" } ?? meeting.id))
    }
    return lines.joined(separator: "\n")
  }

  static func describe(_ status: StatusSnapshot) -> String {
    var lines = [status.summary]
    if let recording = status.recording {
      var details = ["\(duration(recording.elapsedSeconds)) elapsed"]
      if let trigger = recording.trigger { details.append(trigger.rawValue) }
      if let source = recording.source { details.append(source.summary) }
      if recording.mutedInTeams == true { details.append("muted in Teams") }
      lines.append("Recording: \(recording.meetingId) (\(details.joined(separator: ", ")))")
    }
    for work in status.queue {
      var line = "Queue: \(work.meetingId) \(work.status.rawValue)"
      if let stage = work.stage { line += ", \(stage)" }
      lines.append(line)
    }
    for work in status.attention {
      var line = "Needs attention: \(work.meetingId) \(work.status.rawValue)"
      if let error = work.error { line += ": \(error)" }
      line += work.canRetry == false ? " (discard only)" : " (retry or discard)"
      lines.append(line)
    }
    if let reason = status.startBlockedReason, status.running, status.recording == nil {
      lines.append("Cannot start: \(reason)")
    }
    if let last = status.lastTranscriptId { lines.append("Last transcript: \(last)") }
    lines.append(
      "Auto-record Teams meetings: \(status.settings.autoRecordTeamsMeetings ? "on" : "off"); mirror Teams mute: \(status.settings.mirrorTeamsMute ? "on" : "off")"
    )
    if let error = status.settings.configError { lines.append("config.json error: \(error)") }
    if let version = status.version { lines.append("Version: \(version)") }
    return lines.joined(separator: "\n")
  }
}

/// The `meeting-notes` command: a two-line script in `~/.local/bin` that runs the app's
/// executable. The installed app writes it at every launch, so installing or updating the app
/// keeps it current. A file of that name that is not this script is left alone.
enum CommandLineShim {
  static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
  }

  /// Login shells read this profile; desktop MCP clients use the app's absolute path.
  @discardableResult
  static func installShellPath(in profile: URL) throws -> Bool {
    let stanza = """
      if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
      fi
      """
    let manager = FileManager.default
    let exists = manager.fileExists(atPath: profile.path)
    let contents = exists ? try String(contentsOf: profile, encoding: .utf8) : ""
    guard !contents.contains(stanza) else { return false }
    let suffix = (contents.isEmpty || contents.hasSuffix("\n") ? "" : "\n") + stanza + "\n"
    if exists {
      let handle = try FileHandle(forWritingTo: profile)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(suffix.utf8))
    } else {
      try Data(suffix.utf8).write(to: profile, options: .withoutOverwriting)
    }
    return true
  }

  /// Writes the script unless it is already current; returns whether it changed anything.
  @discardableResult
  static func install(executable: String, in directory: URL = directory) throws -> Bool {
    let shim = directory.appendingPathComponent("meeting-notes")
    let script = "#!/bin/sh\nexec \(AgentSetup.quoted(executable)) \"$@\"\n"
    if let existing = try? String(contentsOf: shim, encoding: .utf8) {
      if existing == script { return false }
      guard existing.contains("MeetingNotes") else {
        throw MeetingError(
          "\(shim.path) exists and is not a Meeting Notes command; nothing was changed.")
      }
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(script.utf8).write(to: shim, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    return true
  }
}

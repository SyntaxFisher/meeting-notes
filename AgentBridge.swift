import AppKit
import Foundation

/// Operations shared by the command-line interface and the MCP server. Reads go straight to the
/// files in the meetings folder; actions go through the running app's control socket, where
/// the app's command layer validates them like any other surface.
struct AgentBridge {
  enum WaitOutcome {
    case ready(MeetingRecord)
    case timedOut(StatusSnapshot)
  }

  static let bundleIdentifier = "com.jona.meeting-notes"
  var configFile = AutomationPaths.standard.configFile
  var socket = ControlChannel.defaultSocketURL
  var allowsAppLaunch = true
  let library: MeetingLibrary

  init(library: MeetingLibrary? = nil) {
    if let library {
      self.library = library
    } else {
      let root = (try? AppConfig.read(from: AutomationPaths.standard.configFile))?.meetingsRootURL
      self.library = MeetingLibrary(root: root ?? MeetingFiles.root)
    }
  }

  func status() -> StatusSnapshot {
    if let status = try? ControlClient.send(
      ControlRequest(command: "status"), socket: socket, timeout: 5
    ).status {
      return status
    }
    var status = StatusSnapshot.offline(library: library, configFile: configFile)
    if isAppProcessRunning {
      status.summary =
        "Meeting Notes is running but does not answer on its control socket. Update it to a version with agent support or relaunch it."
    }
    return status
  }

  var isServing: Bool { ControlClient.isServing(socket: socket) }

  /// Sends an action to the app, launching it first when it is not running.
  func perform(_ command: String, _ arguments: [String: JSONValue] = [:]) throws
    -> ControlResponse
  {
    let request = ControlRequest(command: command, arguments: arguments)
    do {
      return try ControlClient.send(request, socket: socket)
    } catch is ControlClient.NotRunning {
      guard allowsAppLaunch else {
        throw MeetingError("App controls are unavailable in this isolated meeting library.")
      }
      try launchApp()
      return try ControlClient.send(request, socket: socket)
    }
  }

  /// Changes settings through the running app, or directly in config.json when it is not
  /// running. Both apply the same validation, and the app picks up file edits live.
  func updateSettings(_ change: SettingsChange) throws -> String {
    guard !change.isEmpty else { throw MeetingError("No setting was given.") }
    try change.validate()
    if isServing {
      var arguments: [String: JSONValue] = [:]
      if let value = change.autoRecordTeamsMeetings {
        arguments["auto_record_teams_meetings"] = .bool(value)
      }
      if let value = change.mirrorTeamsMute { arguments["mirror_teams_mute"] = .bool(value) }
      if let value = change.localSpeakerName {
        arguments["local_speaker_name"] = .string(value ?? "")
      }
      if let value = change.audioBytes {
        arguments["retention_audio_bytes"] = .number(Double(value))
      }
      let response = try ControlClient.send(
        ControlRequest(command: "set_settings", arguments: arguments), socket: socket)
      guard response.ok else {
        throw MeetingError(response.message ?? "Settings were not changed.")
      }
      return response.message ?? "Settings updated."
    }
    try AppConfig.edit(configFile) { change.apply(to: &$0) }
    return "Settings updated in \(configFile.path); Meeting Notes applies them when it starts."
  }

  var isAppProcessRunning: Bool {
    allowsAppLaunch
      && !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        .isEmpty
  }

  /// Opens the app bundle this executable belongs to, so the CLI always drives a matching app.
  func launchApp(timeout: TimeInterval = 20) throws {
    let bundle = Bundle.main.bundleURL
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments =
      bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", Self.bundleIdentifier]
    try process.run()
    process.waitUntilExit()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if ControlClient.isServing(socket: socket) { return }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw MeetingError(
      isAppProcessRunning
        ? "Meeting Notes is running but does not answer on its control socket. Update it to a version with agent support or relaunch it."
        : "Meeting Notes did not start within \(Int(timeout)) seconds.")
  }

  /// Blocks until a transcript is ready. With a meeting id, waits for that meeting wherever it
  /// is in its lifecycle. Without one, waits for the next transcript to finish: of the meetings
  /// recording, saving, queued or transcribing now, or of the next meeting that starts.
  func waitForTranscript(
    meetingId: String?, timeout: TimeInterval, pollInterval: TimeInterval = 1,
    progress: ((StatusSnapshot) -> Void)? = nil
  ) throws -> WaitOutcome {
    let deadline = Date().addingTimeInterval(timeout)
    let began = Date()
    var tracked: [String] = []
    if let meetingId {
      tracked = [try library.resolve(meetingId)]
    } else {
      tracked = library.meetings().filter(\.status.isInProgress).map(\.id).reversed()
    }
    var lastSummary = ""
    while true {
      let meetings = Dictionary(
        library.meetings().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      if meetingId == nil {
        for record in meetings.values.sorted(by: { $0.startedAt < $1.startedAt })
        where record.status.isInProgress && record.startedAt >= began.addingTimeInterval(-60)
          && !tracked.contains(record.id)
        {
          tracked.append(record.id)
        }
      }
      for id in tracked {
        guard let record = meetings[id] else {
          if meetingId != nil {
            throw MeetingError(
              "\"\(id)\" was discarded: it was moved to the Trash or contained no speech.")
          }
          continue
        }
        if record.status == .complete { return .ready(record) }
        if record.status.needsAttention {
          throw MeetingError(
            "\"\(id)\" needs attention: \(record.error ?? record.status.rawValue). Retry it with retry \"\(id)\" or discard it."
          )
        }
      }
      tracked.removeAll { meetings[$0] == nil }
      let status = status()
      if status.summary != lastSummary {
        lastSummary = status.summary
        progress?(status)
      }
      if !status.running {
        throw MeetingError(
          tracked.isEmpty
            ? "Meeting Notes is not running, so no transcript is in progress."
            : "Meeting Notes is not running. Its queue continues when it starts; open it or run start/status."
        )
      }
      if Date() >= deadline { return .timedOut(status) }
      Thread.sleep(forTimeInterval: pollInterval)
    }
  }
}

/// Parses date filters: ISO 8601 timestamps, `yyyy-MM-dd`, `today`, `yesterday`, or a relative
/// age such as `90m`, `12h`, `7d` or `2w`.
enum DateFilter {
  static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws
    -> Date
  {
    let value = text.trimmingCharacters(in: .whitespaces).lowercased()
    if value == "today" { return calendar.startOfDay(for: now) }
    if value == "yesterday" {
      return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
    }
    if let match = value.wholeMatch(of: #/(\d+)\s*([mhdw])/#), let amount = Double(match.1) {
      let unit: Double = ["m": 60, "h": 3600, "d": 86_400, "w": 604_800][String(match.2)]!
      return now.addingTimeInterval(-amount * unit)
    }
    if let date = JSONCoding.parseDate(text.trimmingCharacters(in: .whitespaces)) { return date }
    throw MeetingError(
      "Cannot read the date \"\(text)\". Use an ISO date like 2026-11-05, a timestamp, today, yesterday, or an age like 7d."
    )
  }
}

/// Ready-to-paste commands that register the MCP server with common coding agents, and the
/// checks and commands that register or remove it with one click.
struct AgentSetup {
  static let serverName = "meeting-notes"
  static let manualServerCommand = "meeting-notes mcp"

  var serverCommand: String { Self.manualServerCommand }

  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  struct Agent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The command-line tool that manages the agent's MCP servers.
    let tool: String
    let command: String
    let removeCommand: String
    /// Exits 0 when a server named `meeting-notes` is registered, whatever command it runs.
    let check: String
  }

  var agents: [Agent] {
    let server = Self.serverName
    return [
      Agent(
        id: "codex", name: "Codex", tool: "codex",
        command: "codex mcp add \(server) -- \(serverCommand)",
        removeCommand: "codex mcp remove \(server)",
        check: "codex mcp get \(server)"),
      Agent(
        id: "claude", name: "Claude Code", tool: "claude",
        command: "claude mcp add --scope user \(server) -- \(serverCommand)",
        removeCommand: "claude mcp remove --scope user \(server)",
        check: "claude mcp get \(server)"),
      Agent(
        id: "pi", name: "pi", tool: "pi",
        command: "pi mcp add \(server) -- \(serverCommand)",
        removeCommand: "pi mcp remove \(server)",
        check:
          "grep -q '\"\(server)\"' \"${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/mcp.json\""),
    ]
  }

  var shellCommands: String {
    agents.map { "# \($0.name)\n\($0.command)" }.joined(separator: "\n")
  }
}

/// Whether an agent can use Meeting Notes, found by running its own command-line tool.
enum AgentConnection: Equatable, Sendable {
  case checking
  case notInstalled
  case notConnected
  case connected
  /// Connecting failed with the tool's output.
  case failed(String)
  /// Removing failed with the tool's output.
  case removeFailed(String)

  var isFailure: Bool {
    switch self {
    case .failed, .removeFailed: return true
    default: return false
    }
  }

  /// The state to show after a background check: a failure stays visible until the check finds
  /// that the failed action has taken effect after all, or the agent has gone.
  func updated(by check: AgentConnection) -> AgentConnection {
    switch self {
    case .failed where check == .notConnected: return self
    case .removeFailed where check == .connected: return self
    default: return check
    }
  }
}

/// Runs the agents' command-line tools in a login shell, so the user's PATH and agent
/// configuration variables (CODEX_HOME, CLAUDE_CONFIG_DIR, PI_CODING_AGENT_DIR) apply.
enum AgentConnector {
  struct Output: Sendable {
    let status: Int32
    let text: String
  }

  static func shell(_ command: String, timeout: TimeInterval = 30) -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch {
      return Output(status: -1, text: error.localizedDescription)
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
      process.terminate()
      return Output(status: -1, text: "Timed out after \(Int(timeout)) seconds.")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return Output(
      status: process.terminationStatus,
      text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// One login shell per agent, because Settings repeats this every few seconds.
  static func state(of agent: AgentSetup.Agent) -> AgentConnection {
    let notInstalled: Int32 = 127
    let status = shell(
      "command -v \(agent.tool) >/dev/null 2>&1 || exit \(notInstalled)\n\(agent.check)"
    ).status
    if status == notInstalled { return .notInstalled }
    return status == 0 ? .connected : .notConnected
  }

  /// Registers the MCP server and confirms it with the agent's own check.
  static func connect(_ agent: AgentSetup.Agent) -> AgentConnection {
    let output = shell(
      """
      command -v meeting-notes >/dev/null 2>&1 || {
        echo 'Open Meeting Notes from Applications and add ~/.local/bin to your PATH.'
        exit 1
      }
      \(agent.command)
      """)
    guard output.status == 0 else { return .failed(message(output, agent)) }
    return state(of: agent) == .connected
      ? .connected
      : .failed("\(agent.tool) reported success, but the server is not listed:\n\(output.text)")
  }

  /// Removes the MCP server and confirms with the agent's own check that it is gone.
  static func disconnect(_ agent: AgentSetup.Agent) -> AgentConnection {
    let output = shell(agent.removeCommand)
    guard output.status == 0 else { return .removeFailed(message(output, agent)) }
    let state = state(of: agent)
    return state == .connected
      ? .removeFailed(
        "\(agent.tool) reported success, but the server is still listed:\n\(output.text)")
      : state
  }

  private static func message(_ output: Output, _ agent: AgentSetup.Agent) -> String {
    output.text.isEmpty ? "\(agent.tool) exited with \(output.status)." : output.text
  }
}

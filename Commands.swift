import Foundation

/// An action on meetings or settings. Every surface (panel, library window, control
/// socket for the command line and MCP, URL scheme, Shortcuts) sends these to `CommandCenter`,
/// so the same validation applies everywhere and a refused action gives the same reason.
enum MeetingCommand: Equatable {
  case start(title: String?)
  case stop
  case stopAndDiscard
  /// Stop when recording, otherwise start.
  case toggleRecording
  /// Without an id: the one meeting that needs attention.
  case retry(id: String?)
  /// Moves an unfinished meeting to the Trash, cancelling its saving or transcription.
  /// Without an id: the one meeting that needs attention.
  case discard(id: String?)
  case delete(id: String)
  case open(MeetingLink)
  /// Without an id: the recording in progress.
  case setTitle(id: String?, title: String)
  case renameSpeakers(id: String, names: [String: String?])
  case updateSettings(SettingsChange)

  var name: String {
    switch self {
    case .start: "start"
    case .stop: "stop"
    case .stopAndDiscard: "stop_and_discard"
    case .toggleRecording: "toggle_recording"
    case .retry: "retry"
    case .discard: "discard"
    case .delete: "delete"
    case .open: "open_meeting"
    case .setTitle: "set_title"
    case .renameSpeakers: "rename_speakers"
    case .updateSettings: "update_settings"
    }
  }
}

struct SettingsChange: Equatable, Sendable {
  var autoRecordTeamsMeetings: Bool?
  var mirrorTeamsMute: Bool?
  var playSounds: Bool?
  var recognizeVoices: Bool?
  var agentsMayNameMeetings: Bool?
  /// `.some(nil)` restores the default name.
  var localSpeakerName: String??
  var audioBytes: Int64?

  var isEmpty: Bool { self == SettingsChange() }

  /// Rejects values config.json would not accept, so a change never makes the file invalid.
  func validate() throws {
    if let bytes = audioBytes, bytes < 1 {
      throw MeetingError("A storage limit must be at least 1 byte.")
    }
  }

  func apply(to config: inout AppConfig) {
    if let value = autoRecordTeamsMeetings { config.autoRecordTeamsMeetings = value }
    if let value = mirrorTeamsMute { config.mirrorTeamsMute = value }
    if let value = playSounds { config.playSounds = value }
    if let value = recognizeVoices { config.recognizeVoices = value }
    if let value = agentsMayNameMeetings { config.agentsMayNameMeetings = value }
    if let value = localSpeakerName { config.localSpeakerName = value }
    if let value = audioBytes { config.retention.audioBytes = value }
  }
}

struct CommandOutcome {
  var message: String
  var meeting: MeetingRecord?
}

/// Where a command came from, for the event log and diagnostics.
enum CommandSource: String {
  case panel, library, socket, url, shortcuts
  case autoRecord = "auto-record"
}

/// Validates and runs `MeetingCommand`s. Each accepted or refused command is logged to
/// `events.jsonl` as `command.accepted` or `command.rejected` with its reason.
@MainActor
final class CommandCenter {
  struct Context {
    var permissions: () -> PermissionSnapshot
    var requestingPermissions: () -> Bool
    var updateInstalling: () -> Bool
    var refreshPermissions: () async -> Void
    /// Every meeting, read without blocking the main actor; nil reads the engine's library.
    var meetings: (() async -> [MeetingRecord])? = nil
    /// Why the meetings folder cannot be used now, or nil when it can.
    var folderUnavailable: () -> String? = { nil }
    var waitForFolderAccess: (() async throws -> Void)? = nil
    var openMeeting: ((MeetingLink) async throws -> Void)? = nil
  }

  let engine: MeetingEngine
  let config: ConfigStore
  let teams: TeamsMonitor
  private let context: Context
  var events = EventLog.shared

  init(engine: MeetingEngine, config: ConfigStore, teams: TeamsMonitor, context: Context) {
    self.engine = engine
    self.config = config
    self.teams = teams
    self.context = context
  }

  /// Why a recording cannot start now, or nil when it can. Earlier meetings that are still
  /// saving, queued or transcribing never block a new recording.
  var startBlockedReason: String? {
    startBlockedReason(automatically: false)
  }

  func startBlockedReason(automatically: Bool) -> String? {
    if let record = engine.recordingRecord {
      return "Already recording \"\(record.title ?? record.id)\"."
    }
    if engine.isStarting { return "A recording is starting." }
    if let reason = context.folderUnavailable() { return reason }
    if context.updateInstalling() { return "An update is being installed." }
    if context.requestingPermissions() { return "Permission setup is in progress." }
    let missing = context.permissions().missingForRecording(automatically: automatically)
    if !missing.isEmpty {
      return
        "Missing permissions: \(missing.map(\.title).joined(separator: ", ")). Open Meeting Notes and choose Set Up Permissions."
    }
    return nil
  }

  @discardableResult
  func perform(_ command: MeetingCommand, source: CommandSource) async -> Result<
    CommandOutcome, MeetingError
  > {
    let result: Result<CommandOutcome, MeetingError>
    if ["start", "stop", "stop_and_discard", "toggle_recording"].contains(command.name) {
      TeamsTrace.shared.record(
        "command", always: true, ["command": command.name, "source": source.rawValue])
    }
    do {
      result = .success(try await run(command))
    } catch let error as MeetingError {
      result = .failure(error)
    } catch {
      result = .failure(MeetingError(error.localizedDescription))
    }
    var details: [String: Any] = ["command": command.name, "source": source.rawValue]
    switch result {
    case .success(let outcome):
      details["message"] = outcome.message
      events.record("command.accepted", meeting: outcome.meeting?.id, details: details)
      AppLog.event("command.accepted", "\(command.name); \(source.rawValue)")
    case .failure(let error):
      details["reason"] = error.message
      events.record("command.rejected", details: details)
      AppLog.event("command.rejected", "\(command.name); \(source.rawValue); \(error.message)")
    }
    return result
  }

  private func run(_ command: MeetingCommand) async throws -> CommandOutcome {
    if case .open = command { try await context.waitForFolderAccess?() }
    switch command {
    case .updateSettings, .stop, .stopAndDiscard: break
    default:
      if let reason = context.folderUnavailable() { throw MeetingError(reason) }
    }
    switch command {
    case .start(let title):
      return try await start(title: title, automatically: false)
    case .stop:
      let record = try await engine.stopRecording()
      return CommandOutcome(
        message:
          "Recording stopped. It is saved and queued for transcription; wait for the transcript.",
        meeting: record)
    case .stopAndDiscard:
      let record = try await engine.stopRecording(discard: true)
      return CommandOutcome(
        message: "Recording stopped and moved to the Trash.", meeting: record)
    case .toggleRecording:
      return engine.active == nil ? try await run(.start(title: nil)) : try await run(.stop)
    case .retry(let id):
      let record = try engine.retry(try await attentionID(id, verb: "retry"))
      return CommandOutcome(
        message: record.status == .saving
          ? "Saving the captured audio, then transcribing it."
          : "Queued for transcription; wait for the transcript.",
        meeting: record)
    case .discard(let id):
      let record = try await engine.discard(try await attentionID(id, verb: "discard"))
      return CommandOutcome(
        message: "\"\(record.title ?? record.id)\" was moved to the Trash.", meeting: record)
    case .delete(let id):
      let resolved = try await resolve(id)
      let record: MeetingRecord
      if resolved == engine.active?.id {
        record = try await engine.stopRecording(discard: true)
      } else if try engine.library.load(resolved).status == .complete {
        record = try engine.delete(resolved)
      } else {
        record = try await engine.discard(resolved)
      }
      return CommandOutcome(
        message: "\"\(record.title ?? record.id)\" was moved to the Trash.", meeting: record)
    case .open(let link):
      let record = try engine.library.load(link.meetingID)
      try link.validate(in: record)
      guard let openMeeting = context.openMeeting else {
        throw MeetingError("The meeting window is unavailable.")
      }
      try await openMeeting(link)
      return CommandOutcome(message: "Opened in Meeting Notes.", meeting: record)
    case .setTitle(let id, let title):
      guard let id else {
        let record = try engine.setRecordingTitle(title)
        return CommandOutcome(message: "Title set.", meeting: record)
      }
      let resolved = try await resolve(id)
      if resolved == engine.active?.id {
        return CommandOutcome(
          message: "Title set.", meeting: try engine.setRecordingTitle(title))
      }
      let record = try engine.library.setTitle(resolved, title: title)
      return CommandOutcome(message: "Title set.", meeting: record)
    case .renameSpeakers(let id, let names):
      let record = try engine.library.renameSpeakers(try await resolve(id), names: names)
      return CommandOutcome(message: "Speakers renamed.", meeting: record)
    case .updateSettings(let change):
      guard !change.isEmpty else { throw MeetingError("No setting was given.") }
      try change.validate()
      try config.update { change.apply(to: &$0) }
      return CommandOutcome(message: "Settings updated in \(config.file.path).")
    }
  }

  /// Starts an automatic recording through the same checks as a manual one.
  @discardableResult
  func startAutomatically() async -> MeetingError? {
    do {
      _ = try await start(title: nil, automatically: true)
      events.record(
        "command.accepted",
        details: ["command": "start", "source": CommandSource.autoRecord.rawValue])
    } catch {
      events.record(
        "command.rejected",
        details: [
          "command": "start", "source": CommandSource.autoRecord.rawValue,
          "reason": error.localizedDescription,
        ])
      return MeetingError(error.localizedDescription)
    }
    return nil
  }

  private func start(
    title: String?, automatically: Bool
  ) async throws -> CommandOutcome {
    if let reason = startBlockedReason(automatically: automatically) {
      throw MeetingError(reason)
    }
    await context.refreshPermissions()
    if let reason = startBlockedReason(automatically: automatically) {
      throw MeetingError(reason)
    }
    let record = try await engine.startRecording(
      title: title, automatically: automatically)
    return CommandOutcome(message: "Recording started.", meeting: record)
  }

  /// Resolves the meeting a retry or discard refers to. Without an id, exactly one meeting may
  /// need attention, so a command can never pick the wrong one.
  private func attentionID(_ id: String?, verb: String) async throws -> String {
    if let id { return try await resolve(id) }
    let candidates = Array(await meetings().filter(\.status.needsAttention).reversed())
    switch candidates.count {
    case 0: throw MeetingError("No failed or interrupted meeting is waiting to \(verb).")
    case 1: return candidates[0].id
    default:
      throw MeetingError(
        "\(candidates.count) meetings need attention; pass the id of the one to \(verb): "
          + candidates.map { "\"\($0.id)\"" }.joined(separator: ", ") + ".")
    }
  }

  private func meetings() async -> [MeetingRecord] {
    if let meetings = context.meetings { return await meetings() }
    return engine.library.meetings()
  }

  private func resolve(_ reference: String) async throws -> String {
    try MeetingLibrary.resolve(reference, in: await meetings())
  }

  // MARK: Status

  func status() async -> StatusSnapshot {
    let library = engine.library
    let meetings = await meetings()
    var recording: StatusSnapshot.Recording?
    if let record = engine.recordingRecord {
      recording = StatusSnapshot.Recording(
        meetingId: record.id, title: record.title, startedAt: record.startedAt,
        elapsedSeconds: Date().timeIntervalSince(record.startedAt).rounded(),
        trigger: record.trigger, source: record.source,
        mutedInTeams: teams.mirroredRecorder == nil ? nil : teams.currentState?.microphoneMuted)
    }
    let queue = (engine.saving + engine.queue).map { StatusSnapshot.work($0, library: library) }
    let attention = meetings.filter(\.status.needsAttention).reversed().map {
      StatusSnapshot.work($0, library: library)
    }
    let blocked = startBlockedReason
    var sentences: [String] = []
    if let recording {
      sentences.append("Recording \"\(recording.title ?? recording.meetingId)\".")
    } else if engine.isStarting {
      sentences.append("Starting a recording.")
    } else {
      sentences.append(blocked == nil ? "Ready to record." : "Cannot record: \(blocked!)")
    }
    if let current = engine.queue.first(where: { $0.status == .transcribing }) {
      sentences.append(
        "Transcribing \"\(current.title ?? current.id)\": \(current.stage ?? "starting").")
    }
    let waiting = engine.queue.filter { $0.status == .queued }.count + engine.saving.count
    if waiting > 0 {
      sentences.append("\(StatusSnapshot.count(waiting, "meeting")) waiting for transcription.")
    }
    if !attention.isEmpty {
      sentences.append(
        "\(StatusSnapshot.count(attention.count, "meeting")) need\(attention.count == 1 ? "s" : "") attention."
      )
    }
    let teamsStatus: StatusSnapshot.Teams? =
      teams.isRunning
      ? StatusSnapshot.Teams(
        meetingDetected: teams.meetingPresence.flatMap {
          switch $0 {
          case .inMeeting, .connecting: return true
          case .noMeeting: return false
          case .unknown: return nil
          }
        }, meetingTitle: teams.meetingTitle) : nil
    return StatusSnapshot(
      running: true, version: StatusSnapshot.appVersion,
      summary: sentences.joined(separator: " "), recording: recording,
      startingRecording: engine.isStarting, queue: queue, attention: Array(attention),
      canStartRecording: blocked == nil, startBlockedReason: blocked,
      lastTranscriptId: meetings.first { $0.status == .complete }?.id,
      missingPermissions: context.permissions().missingForRecording()
        .map(\.rawValue),
      settings: StatusSnapshot.settings(config.config, file: config.file, error: config.problem),
      teams: teamsStatus)
  }

  // MARK: Control socket

  /// Serves one control-socket request.
  func handle(_ request: ControlRequest) async -> ControlResponse {
    let arguments = request.arguments
    func string(_ key: String) -> String? {
      guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespaces),
        !value.isEmpty
      else { return nil }
      return value
    }
    let command: MeetingCommand
    switch request.command {
    case "ping", "status":
      return ControlResponse(ok: true, message: "OK", status: await status())
    case "start":
      guard arguments["source"] == nil else {
        return .failure("Recording sources are selected automatically.", status: await status())
      }
      command = .start(title: string("title"))
    case "stop":
      command = arguments["discard"]?.boolValue == true ? .stopAndDiscard : .stop
    case "retry": command = .retry(id: string("meeting_id"))
    case "discard": command = .discard(id: string("meeting_id"))
    case "delete":
      guard let id = string("meeting_id") else {
        return .failure("Pass meeting_id.", status: await status())
      }
      command = .delete(id: id)
    case "open_meeting":
      guard let value = string("url"), let url = URL(string: value),
        let link = MeetingLink(url: url)
      else { return .failure("Pass a valid meeting URL.") }
      command = .open(link)
    case "set_title":
      guard let title = string("title") else {
        return .failure("Pass a title.", status: await status())
      }
      command = .setTitle(id: string("meeting_id"), title: title)
    case "rename_speakers":
      guard let id = string("meeting_id"), let names = arguments["speakers"]?.objectValue else {
        return .failure("Pass meeting_id and speakers.", status: await status())
      }
      command = .renameSpeakers(id: id, names: names.mapValues { $0.stringValue })
    case "set_settings":
      var change = SettingsChange()
      change.autoRecordTeamsMeetings = arguments["auto_record_teams_meetings"]?.boolValue
      change.mirrorTeamsMute = arguments["mirror_teams_mute"]?.boolValue
      change.playSounds = arguments["play_sounds"]?.boolValue
      change.agentsMayNameMeetings = arguments["agents_may_name_meetings"]?.boolValue
      if let name = arguments["local_speaker_name"] {
        change.localSpeakerName = .some(name.stringValue.flatMap { $0.isEmpty ? nil : $0 })
      }
      func bytes(_ key: String) -> Int64? {
        arguments[key]?.doubleValue.flatMap { Int64(exactly: $0) }
      }
      change.audioBytes = bytes("retention_audio_bytes")
      command = .updateSettings(change)
    default:
      return .failure("Unknown command \"\(request.command)\".", status: await status())
    }
    switch await perform(command, source: .socket) {
    case .success(let outcome):
      return ControlResponse(
        ok: true, message: outcome.message, meetingId: outcome.meeting?.id, status: await status())
    case .failure(let error):
      return .failure(error.message, status: await status())
    }
  }
}

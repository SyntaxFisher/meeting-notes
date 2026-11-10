import Foundation

/// What the app is doing, shared by the control socket, the command line and MCP. Built from
/// the running app, or from the files when it is not running.
struct StatusSnapshot: Codable, Equatable, Sendable {
  struct Recording: Codable, Equatable, Sendable {
    var meetingId: String
    var title: String?
    var startedAt: Date
    var elapsedSeconds: Double
    var trigger: MeetingTrigger?
    var source: MeetingSource?
    var mutedInTeams: Bool?

    enum CodingKeys: String, CodingKey {
      case meetingId = "meeting_id"
      case title
      case startedAt = "started_at"
      case elapsedSeconds = "elapsed_seconds"
      case trigger, source
      case mutedInTeams = "muted_in_teams"
    }
  }

  struct Work: Codable, Equatable, Sendable {
    var meetingId: String
    var title: String?
    var status: MeetingStatus
    var stage: String?
    var progress: Double?
    var error: String?
    var failedAt: Date?
    var canRetry: Bool?

    enum CodingKeys: String, CodingKey {
      case meetingId = "meeting_id"
      case title, status, stage, progress, error
      case failedAt = "failed_at"
      case canRetry = "can_retry"
    }
  }

  struct Settings: Codable, Equatable, Sendable {
    var autoRecordTeamsMeetings: Bool
    var mirrorTeamsMute: Bool
    var playSounds: Bool
    var localSpeakerName: String?
    var meetingsRoot: String
    var retentionAudioBytes: Int64
    var configPath: String
    var configError: String?

    enum CodingKeys: String, CodingKey {
      case autoRecordTeamsMeetings = "auto_record_teams_meetings"
      case mirrorTeamsMute = "mirror_teams_mute"
      case playSounds = "play_sounds"
      case localSpeakerName = "local_speaker_name"
      case meetingsRoot = "meetings_root"
      case retentionAudioBytes = "retention_audio_bytes"
      case configPath = "config_path"
      case configError = "config_error"
    }
  }

  struct Teams: Codable, Equatable, Sendable {
    var meetingDetected: Bool?
    var meetingTitle: String?

    enum CodingKeys: String, CodingKey {
      case meetingDetected = "meeting_detected"
      case meetingTitle = "meeting_title"
    }
  }

  var running: Bool
  var version: String?
  /// One or two sentences for people, such as "Recording "Weekly Sync". 1 meeting is queued."
  var summary: String
  var recording: Recording?
  var startingRecording: Bool
  /// Meetings being saved, waiting for transcription or transcribing, in processing order.
  var queue: [Work]
  /// Failed, interrupted and untranscribed meetings, oldest first. Each can be retried or
  /// discarded.
  var attention: [Work]
  var canStartRecording: Bool
  var startBlockedReason: String?
  var lastTranscriptId: String?
  var missingPermissions: [String]
  var settings: Settings
  var teams: Teams?

  enum CodingKeys: String, CodingKey {
    case running, version, summary, recording
    case startingRecording = "starting_recording"
    case queue, attention
    case canStartRecording = "can_start_recording"
    case startBlockedReason = "start_blocked_reason"
    case lastTranscriptId = "last_transcript_id"
    case missingPermissions = "missing_permissions"
    case settings, teams
  }

  static var appVersion: String? {
    guard let info = Bundle.main.infoDictionary,
      let version = info["CFBundleShortVersionString"] as? String
    else { return nil }
    return "\(version) (\(info["CFBundleVersion"] as? String ?? "?"))"
  }

  static func work(_ record: MeetingRecord, library: MeetingLibrary) -> Work {
    Work(
      meetingId: record.id, title: record.title, status: record.status, stage: record.stage,
      progress: record.progress, error: record.error, failedAt: record.failedAt,
      canRetry: record.status.needsAttention ? library.work(for: record).canRetry : nil)
  }

  static func settings(_ config: AppConfig, file: URL, error: String?) -> Settings {
    Settings(
      autoRecordTeamsMeetings: config.autoRecordTeamsMeetings,
      mirrorTeamsMute: config.mirrorTeamsMute, playSounds: config.playSounds,
      localSpeakerName: config.localSpeakerName,
      meetingsRoot: config.meetingsRoot, retentionAudioBytes: config.retention.audioBytes,
      configPath: file.path,
      configError: error)
  }

  /// Describes the app from its files when it is not running.
  static func offline(library: MeetingLibrary, configFile: URL) -> StatusSnapshot {
    let meetings = library.meetings()
    let queue = meetings.filter(\.status.isInProgress).reversed().map { work($0, library: library) }
    let attention = meetings.filter(\.status.needsAttention).reversed().map {
      work($0, library: library)
    }
    var configError: String?
    let config: AppConfig
    do { config = try AppConfig.read(from: configFile) } catch {
      configError = error.localizedDescription
      config = AppConfig()
    }
    var summary = "Meeting Notes is not running."
    if !queue.isEmpty {
      summary += " \(count(queue.count, "meeting")) will continue transcribing when it starts."
    }
    if !attention.isEmpty {
      summary +=
        " \(count(attention.count, "meeting")) need\(attention.count == 1 ? "s" : "") attention."
    }
    return StatusSnapshot(
      running: false, version: appVersion, summary: summary, recording: nil,
      startingRecording: false, queue: Array(queue), attention: Array(attention),
      canStartRecording: false,
      startBlockedReason: "Meeting Notes is not running. Action commands launch it.",
      lastTranscriptId: meetings.first { $0.status == .complete }?.id, missingPermissions: [],
      settings: settings(config, file: configFile, error: configError))
  }

  static func count(_ value: Int, _ noun: String) -> String {
    value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
  }
}

struct ControlRequest: Codable, Equatable, Sendable {
  var command: String
  var arguments: [String: JSONValue] = [:]
}

struct ControlResponse: Codable, Equatable, Sendable {
  var ok: Bool
  var message: String?
  var meetingId: String?
  var status: StatusSnapshot?

  enum CodingKeys: String, CodingKey {
    case ok, message
    case meetingId = "meeting_id"
    case status
  }

  static func failure(_ message: String, status: StatusSnapshot? = nil) -> ControlResponse {
    ControlResponse(ok: false, message: message, status: status)
  }
}

/// The running app's local control channel: a Unix domain socket that accepts one JSON request
/// line per connection and answers with one JSON response line. Only the owning user can
/// connect; the socket file is mode 0600 inside the user's Application Support folder.
enum ControlChannel {
  static var defaultSocketURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Meeting Notes/control.sock")
  }

  static let maximumMessageSize = 1 << 20

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONCoding.encoder().encode(value)
    data.append(0x0A)
    return data
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONCoding.decoder().decode(type, from: data)
  }

  fileprivate static func address(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
      throw MeetingError("The control socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }

  fileprivate static func readLine(from descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count < maximumMessageSize {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          throw MeetingError("Timed out waiting for Meeting Notes to answer.")
        }
        throw MeetingError(
          "Reading from the control socket failed: \(String(cString: strerror(errno)))")
      }
      if count == 0 { break }
      data.append(contentsOf: buffer[0..<count])
      if let newline = data.firstIndex(of: 0x0A) { return data[data.startIndex..<newline] }
    }
    return data
  }

  fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw MeetingError(
            "Writing to the control socket failed: \(String(cString: strerror(errno)))")
        }
        offset += written
      }
    }
  }

  fileprivate static func setTimeout(_ seconds: TimeInterval, on descriptor: Int32) {
    var value = timeval(
      tv_sec: Int(seconds), tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000)
    )
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  }
}

enum ControlClient {
  struct NotRunning: LocalizedError {
    var errorDescription: String? { "Meeting Notes is not running." }
  }

  /// Sends one request and waits for its response. Throws `NotRunning` when nothing listens.
  static func send(
    _ request: ControlRequest, socket path: URL = ControlChannel.defaultSocketURL,
    timeout: TimeInterval = 60
  ) throws -> ControlResponse {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw MeetingError("Cannot create a control socket.") }
    defer { close(descriptor) }
    var address = try ControlChannel.address(for: path.path)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      if [ENOENT, ECONNREFUSED].contains(errno) { throw NotRunning() }
      throw MeetingError("Cannot connect to Meeting Notes: \(String(cString: strerror(errno)))")
    }
    ControlChannel.setTimeout(timeout, on: descriptor)
    try ControlChannel.writeAll(ControlChannel.encode(request), to: descriptor)
    let line = try ControlChannel.readLine(from: descriptor)
    guard !line.isEmpty else {
      throw MeetingError("Meeting Notes closed the connection without answering.")
    }
    return try ControlChannel.decode(ControlResponse.self, from: line)
  }

  static func isServing(socket path: URL = ControlChannel.defaultSocketURL) -> Bool {
    (try? send(ControlRequest(command: "ping"), socket: path, timeout: 2)) != nil
  }
}

final class ControlServer: @unchecked Sendable {
  typealias Handler = @Sendable (ControlRequest) async -> ControlResponse
  private let path: URL
  private let handler: Handler
  private var descriptor: Int32 = -1

  init(socket path: URL = ControlChannel.defaultSocketURL, handler: @escaping Handler) {
    self.path = path
    self.handler = handler
  }

  deinit { stop() }

  func start() throws {
    if ControlClient.isServing(socket: path) {
      throw MeetingError("Another Meeting Notes instance already serves \(path.path).")
    }
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    unlink(path.path)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw MeetingError("Cannot create the control socket.") }
    var address = try ControlChannel.address(for: path.path)
    let previousMask = umask(0o077)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    umask(previousMask)
    guard bound == 0, chmod(path.path, 0o600) == 0, listen(descriptor, 16) == 0 else {
      let message = String(cString: strerror(errno))
      close(descriptor)
      throw MeetingError("Cannot listen on \(path.path): \(message)")
    }
    self.descriptor = descriptor
    let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
    thread.name = "Meeting Notes control socket"
    thread.start()
  }

  func stop() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
    unlink(path.path)
  }

  private func acceptLoop(_ listener: Int32) {
    while true {
      let client = accept(listener, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
        close(client)
        continue
      }
      ControlChannel.setTimeout(10, on: client)
      let handler = handler
      DispatchQueue.global().async {
        let response: ControlResponse
        do {
          let line = try ControlChannel.readLine(from: client)
          let request = try ControlChannel.decode(ControlRequest.self, from: line)
          let semaphore = DispatchSemaphore(value: 0)
          let box = ResponseBox()
          Task {
            box.value = await handler(request)
            semaphore.signal()
          }
          semaphore.wait()
          response = box.value ?? .failure("No response.")
        } catch {
          response = .failure("Invalid request: \(error.localizedDescription)")
        }
        ControlChannel.setTimeout(10, on: client)
        try? ControlChannel.writeAll(ControlChannel.encode(response), to: client)
        close(client)
      }
    }
  }

  private final class ResponseBox: @unchecked Sendable {
    var value: ControlResponse?
  }
}

import Foundation

/// User settings stored in a plain JSON file that people and agents can read and edit. Missing
/// keys use their defaults; a file that fails validation is rejected as a whole.
struct AppConfig: Equatable, Sendable {
  var autoRecordTeamsMeetings = true
  var mirrorTeamsMute = true
  var playSounds = true
  var agentsMayNameMeetings = true
  var agentsMaySummarizeMeetings = true
  var agentsMayCorrectTranscripts = false
  var keepAudio = true
  /// The label for everything the microphone records. Nil uses the Teams display name once it
  /// was detected, otherwise the macOS full name.
  var localSpeakerName: String?
  /// The test harness can isolate its library without changing the user-facing storage location.
  var meetingsRoot: String {
    ProcessInfo.processInfo.environment["MEETING_NOTES_TEST_ROOT"] ?? "~/Documents/meeting-notes"
  }
  var retention = Retention()

  struct Retention: Equatable, Sendable {
    var audioBytes: Int64 = RecordingRetention.audioLimit
  }

  var meetingsRootURL: URL {
    URL(fileURLWithPath: (meetingsRoot as NSString).expandingTildeInPath, isDirectory: true)
      .standardizedFileURL
  }

  struct Parsed: Equatable {
    var config: AppConfig
    var warnings: [String]
  }

  struct Invalid: LocalizedError, Equatable {
    let problems: [String]
    var errorDescription: String? { problems.joined(separator: "; ") }
  }

  static func parse(_ data: Data) throws -> Parsed {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw Invalid(problems: ["config.json is not valid JSON: \(Self.describe(error))"])
    }
    guard let root = object as? [String: Any] else {
      throw Invalid(problems: ["config.json must contain a JSON object"])
    }
    let reader = Reader()
    var config = AppConfig()
    reader.allow(root, keys: Self.topLevelKeys, at: "")
    reader.bool(root, "autoRecordTeamsMeetings") { config.autoRecordTeamsMeetings = $0 }
    reader.bool(root, "mirrorTeamsMute") { config.mirrorTeamsMute = $0 }
    reader.bool(root, "playSounds") { config.playSounds = $0 }
    reader.bool(root, "keepAudio") { config.keepAudio = $0 }
    reader.bool(root, "agentsMayNameMeetings") { config.agentsMayNameMeetings = $0 }
    reader.bool(root, "agentsMaySummarizeMeetings") { config.agentsMaySummarizeMeetings = $0 }
    reader.bool(root, "agentsMayCorrectTranscripts") { config.agentsMayCorrectTranscripts = $0 }
    reader.optionalString(root, "localSpeakerName") { value in
      guard let value else {
        config.localSpeakerName = nil
        return
      }
      guard let name = TranscriptDocument.cleanedName(value) else {
        reader.problems.append("localSpeakerName must be null or a name without a colon")
        return
      }
      config.localSpeakerName = name
    }
    reader.object(root, "retention") { retention in
      reader.allow(retention, keys: ["audioBytes"], at: "retention.")
      reader.integer(retention, "audioBytes", at: "retention.", range: 1...Int64.max) {
        config.retention.audioBytes = $0
      }
    }
    guard reader.problems.isEmpty else { throw Invalid(problems: reader.problems) }
    return Parsed(config: config, warnings: reader.warnings)
  }

  func encoded() throws -> Data {
    let object: [String: Any] = [
      "$schema": Self.schemaURL,
      "autoRecordTeamsMeetings": autoRecordTeamsMeetings,
      "mirrorTeamsMute": mirrorTeamsMute,
      "playSounds": playSounds,
      "agentsMayNameMeetings": agentsMayNameMeetings,
      "agentsMaySummarizeMeetings": agentsMaySummarizeMeetings,
      "agentsMayCorrectTranscripts": agentsMayCorrectTranscripts,
      "keepAudio": keepAudio,
      "localSpeakerName": localSpeakerName ?? NSNull(),
      "retention": [
        "audioBytes": retention.audioBytes
      ],
    ]
    var data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
  }

  static let schemaURL =
    "https://raw.githubusercontent.com/SyntaxFisher/meeting-notes/main/docs/config.schema.json"

  private static let topLevelKeys: Set<String> = [
    "$schema", "autoRecordTeamsMeetings", "mirrorTeamsMute", "localSpeakerName",
    "retention", "agentsMayNameMeetings", "agentsMaySummarizeMeetings",
    "agentsMayCorrectTranscripts", "keepAudio", "playSounds",
  ]

  private static func describe(_ error: Error) -> String {
    let nsError = error as NSError
    return (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? nsError.localizedDescription
  }

  private final class Reader {
    var problems: [String] = []
    var warnings: [String] = []

    func allow(_ object: [String: Any], keys: Set<String>, at prefix: String) {
      for key in object.keys.sorted() where !keys.contains(key) {
        warnings.append("Unknown setting \(prefix)\(key) is ignored")
      }
    }

    func bool(
      _ object: [String: Any], _ key: String, at prefix: String = "", apply: (Bool) -> Void
    ) {
      guard let value = object[key] else { return }
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        problems.append("\(prefix)\(key) must be true or false")
        return
      }
      apply(number.boolValue)
    }

    func string(_ object: [String: Any], _ key: String, apply: (String) -> Void) {
      guard let value = object[key] else { return }
      guard let string = value as? String, !string.isEmpty else {
        problems.append("\(key) must be a non-empty string")
        return
      }
      apply(string)
    }

    func optionalString(
      _ object: [String: Any], _ key: String, at prefix: String = "", apply: (String?) -> Void
    ) {
      guard let value = object[key] else { return }
      if value is NSNull {
        apply(nil)
        return
      }
      guard let string = value as? String else {
        problems.append("\(prefix)\(key) must be a string or null")
        return
      }
      apply(string)
    }

    func integer(
      _ object: [String: Any], _ key: String, at prefix: String, range: ClosedRange<Int64>,
      apply: (Int64) -> Void
    ) {
      guard let value = object[key] else { return }
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue == number.doubleValue.rounded(),
        let integer = Int64(exactly: number.doubleValue), range.contains(integer)
      else {
        problems.append(
          "\(prefix)\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        return
      }
      apply(integer)
    }

    func object(
      _ object: [String: Any], _ key: String, apply: ([String: Any]) -> Void
    ) {
      guard let value = object[key] else { return }
      guard let nested = value as? [String: Any] else {
        problems.append("\(key) must be a JSON object")
        return
      }
      apply(nested)
    }
  }
}

extension AppConfig {
  /// The configuration in `file`, or the defaults when it does not exist.
  static func read(from file: URL) throws -> AppConfig {
    guard FileManager.default.fileExists(atPath: file.path) else { return AppConfig() }
    return try parse(Data(contentsOf: file)).config
  }

  /// Changes `file` without the app, for the command line. An invalid file is never replaced.
  @discardableResult
  static func edit(_ file: URL, _ change: (inout AppConfig) -> Void) throws -> AppConfig {
    var config: AppConfig
    do { config = try read(from: file) } catch {
      throw MeetingError(
        "\(file.path) is invalid, so it was not changed: \(error.localizedDescription)")
    }
    change(&config)
    try config.write(to: file)
    return config
  }

  func write(to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded().write(to: file, options: .atomic)
  }
}

/// Paths of the agent-facing automation files.
struct AutomationPaths {
  let configDirectory: URL
  let logDirectory: URL

  static let standard = AutomationPaths(
    configDirectory: ProcessInfo.processInfo.environment["MEETING_NOTES_CONFIG_DIR"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/meeting-notes", isDirectory: true),
    logDirectory: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Meeting Notes", isDirectory: true))

  var configFile: URL { configDirectory.appendingPathComponent("config.json") }
  var eventsFile: URL { logDirectory.appendingPathComponent("events.jsonl") }
}

/// Loads, writes and watches `config.json`. The last valid configuration stays in effect while
/// the file is invalid, and menu changes are refused until the file is fixed, so a broken file is
/// never overwritten.
@MainActor
final class ConfigStore {
  enum Status: Equatable {
    case valid(warnings: [String])
    case invalid(String)
  }

  let file: URL
  private(set) var config = AppConfig()
  private(set) var status = Status.valid(warnings: [])
  var onChange: ((_ old: AppConfig, _ new: AppConfig) -> Void)?
  var onStatus: ((Status) -> Void)?
  private var lastData: Data?
  private var source: DispatchSourceFileSystemObject?
  private var pendingReload: DispatchWorkItem?
  private var poll: Timer?

  init(file: URL) { self.file = file }

  var isWritable: Bool {
    if case .valid = status { return true }
    return false
  }

  var problem: String? {
    if case .invalid(let message) = status { return message }
    return nil
  }

  /// Reads the file, creating it with the defaults when it does not exist yet.
  func load() {
    if !FileManager.default.fileExists(atPath: file.path) {
      do {
        try write(AppConfig())
        AppLog.event("config.created", file.path)
      } catch {
        report(.invalid("Cannot create \(file.path): \(error.localizedDescription)"))
        return
      }
    }
    reload()
  }

  func reload() {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch {
      lastData = nil
      report(.invalid("Cannot read \(file.path): \(error.localizedDescription)"))
      return
    }
    guard data != lastData else { return }
    lastData = data
    do {
      let parsed = try AppConfig.parse(data)
      let old = config
      config = parsed.config
      report(.valid(warnings: parsed.warnings))
      if old != config { onChange?(old, config) }
    } catch {
      report(.invalid(error.localizedDescription))
    }
  }

  /// Applies a change on top of the file as it is now, so edits made by agents a moment ago are
  /// kept.
  func update(_ change: (inout AppConfig) -> Void) throws {
    reload()
    guard isWritable else {
      throw MeetingError(
        "Fix config.json before changing settings: \(problem ?? "the file is invalid").")
    }
    var next = config
    change(&next)
    let old = config
    try write(next)
    lastData = try? Data(contentsOf: file)
    config = next
    report(.valid(warnings: []))
    if old != next { onChange?(old, next) }
  }

  /// Saves that replace the file are seen through its folder within a moment. Writes into the
  /// existing file do not change the folder, so the file is also compared every two seconds.
  func startWatching() {
    poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
    let directory = file.deletingLastPathComponent()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib],
      queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.scheduleReload() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
  }

  /// Editors save in several steps (temporary file, rename), so changes settle briefly first.
  private func scheduleReload() {
    pendingReload?.cancel()
    let item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.reload() }
    }
    pendingReload = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
  }

  private func write(_ config: AppConfig) throws {
    try config.write(to: file)
  }

  private func report(_ next: Status) {
    guard next != status else { return }
    status = next
    switch next {
    case .valid(let warnings):
      AppLog.event("config.loaded", warnings.joined(separator: "; "))
    case .invalid(let message):
      AppLog.event("config.invalid", message)
    }
    onStatus?(next)
  }
}

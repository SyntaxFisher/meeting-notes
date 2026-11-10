import AppKit

/// What Meeting Notes read from Teams and decided, kept while audio is kept so that detection
/// can be replayed later against the same input.
///
/// Each line is a JSON object with its kind (`k`), the host clock (`t`, seconds since boot,
/// the clock of the capture tracks) and wall time (`w`, seconds since 1970). A line is written
/// only when its kind's content changed. Files roll over across app sessions and stay within
/// `budget`, so a recording's trace includes what happened before it started, and failed
/// starts remain visible next to earlier sessions. Turning off kept audio deletes the trace.
final class TeamsTrace: @unchecked Sendable {
  static let shared = TeamsTrace(
    directory: ReconstructionArchive.cacheRoot
      .appendingPathComponent("teams-trace", isDirectory: true))
  static let fileLimit = 8_000_000
  static let budget: Int64 = 40_000_000
  /// How long before a recording its exported trace starts.
  static let preRoll: TimeInterval = 600

  let directory: URL
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.teams-trace")
  private let lock = NSLock()
  private var active = false
  private var enabled = false
  private var file: URL?
  private var written = 0
  private var failedAt: Double?
  private var last: [String: Data] = [:]
  private var session: [String: Any] = [:]

  init(directory: URL) {
    self.directory = directory
  }

  private var isActive: Bool { lock.withLock { active } }

  /// Starts or stops tracing; stopping deletes every trace file.
  func setEnabled(_ enabled: Bool, session: [String: Any] = [:]) {
    let time = ProcessInfo.processInfo.systemUptime
    let wall = Date().timeIntervalSince1970
    lock.withLock { active = enabled }
    queue.async { [self] in
      self.session = session
      if enabled {
        self.enabled = true
        self.last = [:]
        write("session", session, time: time, wall: wall)
      } else {
        self.enabled = false
        file = nil
        last = [:]
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }

  /// Records `fields` under `kind` unless they equal the last record of that kind and `key`;
  /// `always` records events that can repeat, such as commands.
  func record(_ kind: String, key: String = "", always: Bool = false, _ fields: [String: Any]) {
    guard isActive else { return }
    let time = ProcessInfo.processInfo.systemUptime
    let wall = Date().timeIntervalSince1970
    queue.async { [self] in
      guard enabled, JSONSerialization.isValidJSONObject(fields),
        let content = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
      else { return }
      let slot = kind + "/" + key
      guard always || last[slot] != content else { return }
      last[slot] = content
      write(kind, key: key, content, time: time, wall: wall)
    }
  }

  /// Records an `Encodable` value under `kind`.
  func record<Value: Encodable>(_ kind: String, key: String = "", value: Value) {
    guard isActive, let data = try? JSONEncoder().encode(value),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    record(kind, key: key, object)
  }

  /// The trace lines written between `start` and `end` (wall time), preceded by the last line
  /// of each kind before `start`, including the session header, so a replay begins from the
  /// state the app had then.
  func export(from start: Date, to end: Date) -> Data {
    var data = Data()
    export(from: start, to: end) { data.append($0) }
    return data
  }

  /// `export` written piece by piece to `output`, without holding the trace in memory.
  func export(from start: Date, to end: Date, into output: (Data) throws -> Void) rethrows {
    try queue.sync {
      let (start, end) = (start.timeIntervalSince1970, end.timeIntervalSince1970)
      var before: [Data: (wall: Double, line: Data)] = [:]
      var started = false
      let newline = Data([UInt8(ascii: "\n")])
      for file in files() {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
        for line in data.split(separator: UInt8(ascii: "\n")) {
          guard let (slot, wall) = Self.header(line) else { continue }
          if wall < start {
            before[slot] = (wall, Data(line))
          } else if wall <= end {
            if !started {
              started = true
              for entry in before.values.sorted(by: { $0.wall < $1.wall }) {
                try output(entry.line + newline)
              }
            }
            try output(Data(line) + newline)
          }
        }
      }
      if !started {
        for entry in before.values.sorted(by: { $0.wall < $1.wall }) {
          try output(entry.line + newline)
        }
      }
    }
  }

  /// A line's kind and key, as their raw bytes, and its wall time. Lines start with them:
  /// `{"k":"mute","key":"","t":12.5,"w":1700000000.25,...`, and JSON strings escape quotes, so
  /// the first `,"t":` ends the key.
  private static func header(_ line: Data.SubSequence) -> (slot: Data, wall: Double)? {
    let bytes = [UInt8](line.prefix(512))
    func find(_ pattern: String, from: Int) -> Int? {
      let needle = Array(pattern.utf8)
      guard bytes.count >= needle.count, from <= bytes.count - needle.count else { return nil }
      return (from...(bytes.count - needle.count)).first {
        bytes[$0..<($0 + needle.count)].elementsEqual(needle)
      }
    }
    guard bytes.starts(with: Array(#"{"k":"#.utf8)), let time = find(#","t":"#, from: 5),
      let wallStart = find(#","w":"#, from: time).map({ $0 + 5 })
    else { return nil }
    let wallEnd =
      bytes[wallStart...].firstIndex { $0 == UInt8(ascii: ",") || $0 == UInt8(ascii: "}") }
      ?? bytes.count
    guard let wall = Double(String(decoding: bytes[wallStart..<wallEnd], as: UTF8.self))
    else { return nil }
    return (Data(bytes[5..<time]), wall)
  }

  private func write(
    _ kind: String, key: String = "", _ content: Data,
    time: Double = ProcessInfo.processInfo.systemUptime, wall: Double = Date().timeIntervalSince1970
  ) {
    guard let line = Self.line(kind, key: key, content, time: time, wall: wall) else { return }
    if let failedAt, time - failedAt < 60 { return }
    do {
      if file == nil || written + line.count > Self.fileLimit {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "trace-\(Int(wall * 1000)).jsonl"
        let next = directory.appendingPathComponent(name)
        try Data().write(to: next)
        file = next
        written = 0
        prune()
        if kind != "session", let session = sessionLine(time: time, wall: wall) {
          try append(session, to: next)
        }
      }
      try append(line, to: file!)
      failedAt = nil
    } catch {
      if let file, written == 0 { try? FileManager.default.removeItem(at: file) }
      file = nil
      failedAt = time
    }
  }

  private func write(
    _ kind: String, _ fields: [String: Any], time: Double, wall: Double
  ) {
    guard JSONSerialization.isValidJSONObject(fields),
      let content = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    else { return }
    write(kind, content, time: time, wall: wall)
  }

  /// One trace line: the header `export` reads, then the fields of `content`.
  private static func line(
    _ kind: String, key: String, _ content: Data, time: Double, wall: Double
  ) -> Data? {
    func quoted(_ text: String) -> String? {
      (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]))
        .map { String(decoding: $0, as: UTF8.self) }
    }
    guard let kindJSON = quoted(kind), let keyJSON = quoted(key) else { return nil }
    var line = Data(
      #"{"k":\#(kindJSON),"key":\#(keyJSON),"t":\#((time * 1000).rounded() / 1000),"w":\#(wall)"#
        .utf8)
    let fields = content.dropFirst().dropLast()
    if !fields.isEmpty {
      line.append(UInt8(ascii: ","))
      line.append(contentsOf: fields)
    }
    line.append(contentsOf: Array("}\n".utf8))
    return line
  }

  /// The session header that starts every file, stamped like the line it precedes.
  private func sessionLine(time: Double, wall: Double) -> Data? {
    guard JSONSerialization.isValidJSONObject(session),
      let content = try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
    else { return nil }
    return Self.line("session", key: "", content, time: time, wall: wall)
  }

  private func append(_ data: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    written += data.count
  }

  /// Trace files, oldest first.
  private func files() -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
      .filter { $0.pathExtension == "jsonl" }
      .sorted {
        $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
      }
  }

  private func prune() {
    var files = files()
    func size(_ url: URL) -> Int64 {
      Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    var total = files.reduce(0) { $0 + size($1) }
    while total > Self.budget, files.count > 1 {
      let oldest = files.removeFirst()
      total -= size(oldest)
      try? FileManager.default.removeItem(at: oldest)
    }
  }

  /// The installed Teams version, when Teams runs.
  static var teamsVersion: String? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first
      .flatMap(version(of:))
  }

  static func version(of app: NSRunningApplication) -> String? {
    app.bundleURL.flatMap { Bundle(url: $0) }
      .flatMap { $0.infoDictionary?["CFBundleShortVersionString"] as? String }
  }
}

import Foundation

/// Whether the app can read the meetings folder. macOS holds the first read of a protected
/// folder such as ~/Documents until the user answers its privacy prompt, so the folder is only
/// read off the main actor, and nothing that needs it runs before access is `granted`.
enum MeetingsFolderAccess: Equatable, Sendable {
  case checking
  /// The folder is readable and its first scan is running, after renaming meetings from an
  /// earlier version when `updating`.
  case loading(updating: Bool)
  case granted
  case denied(String)

  var isReadable: Bool {
    switch self {
    case .loading, .granted: return true
    case .checking, .denied: return false
    }
  }
}

/// The meetings folder as last read in the background.
struct LibrarySnapshot: Equatable, Sendable {
  var meetings: [MeetingRecord] = []
  /// Unfinished meetings that have a record file: what recovery continues after a relaunch.
  var recoverable: [MeetingRecord] = []
  /// Meetings that need attention and still have audio or capture tracks to retry.
  var retryable: Set<String> = []
  var audio: [String: URL] = [:]
  var storage = RecordingRetention.Usage()

  var latestComplete: MeetingRecord? { meetings.first { $0.status == .complete } }
  var needingAttention: [MeetingRecord] { meetings.filter(\.status.needsAttention).reversed() }
}

/// Reads the meetings folder on its own serial queue. The `MeetingLibrary` it owns is only used
/// on that queue.
final class LibraryReader: @unchecked Sendable {
  let root: URL
  private let library: MeetingLibrary
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.library", qos: .userInitiated)
  private let probe: @Sendable (URL) throws -> Void

  init(root: URL, probe: @escaping @Sendable (URL) throws -> Void = LibraryReader.listFolder) {
    self.root = root
    self.probe = probe
    library = MeetingLibrary(root: root)
  }

  /// Lists the folder, which waits for the user while macOS asks for access.
  static func listFolder(_ root: URL) throws {
    _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
  }

  /// Renames meetings from earlier versions before anything reads the folder.
  static func migrateFiles(_ root: URL) {
    do {
      let result = try MeetingFilesMigration.run(root: root)
      if !result.migrated.isEmpty || !result.skipped.isEmpty {
        AppLog.event(
          "library.migrated",
          "\(result.migrated.count) meetings; skipped: \(result.skipped.joined(separator: ", "))")
      }
    } catch {
      AppLog.event("library.migrationFailed", error.localizedDescription)
    }
  }

  /// A folder that does not exist yet is readable: it is created with the first recording.
  static func access(after error: Error) -> MeetingsFolderAccess {
    if let error = error as? CocoaError, error.code == .fileReadNoSuchFile { return .granted }
    return .denied(error.localizedDescription)
  }

  func access() async -> MeetingsFolderAccess {
    let root = root
    let probe = probe
    return await run { _ in
      do {
        try probe(root)
        return .granted
      } catch {
        return Self.access(after: error)
      }
    }
  }

  func needsMigration() async -> Bool {
    let root = root
    return await run { _ in MeetingFilesMigration.isNeeded(root: root) }
  }

  func migrate() async {
    let root = root
    await run { _ in Self.migrateFiles(root) }
  }

  func snapshot() async -> LibrarySnapshot {
    await run { library in
      let meetings = library.meetings()
      var snapshot = LibrarySnapshot(
        meetings: meetings, storage: RecordingRetention.usage(root: library.root))
      for record in meetings {
        if let audio = library.audioURL(of: record) { snapshot.audio[record.id] = audio }
        if record.status.needsAttention, library.work(for: record).canRetry {
          snapshot.retryable.insert(record.id)
        }
      }
      snapshot.recoverable = library.recoverable(meetings)
      return snapshot
    }
  }

  /// Applies retention to recordings and reconstruction archives, also protecting every meeting
  /// that needs attention.
  func enforceRetention(protected: Set<String>, audioBudget: Int64, keepAudio: Bool) async {
    await run { library in
      let ids = protected.union(library.needingAttention().map(\.id))
      ReconstructionArchive.enforce(
        keepAudio: keepAudio, protected: ids,
        exists: { FileManager.default.fileExists(atPath: library.recordURL(for: $0).path) })
      do {
        try RecordingRetention.enforce(
          root: library.root, protected: ids, audioBudget: audioBudget)
      } catch {
        AppLog.event("retention.failed", error.localizedDescription)
      }
    }
  }

  /// What retention would delete with these budgets, protecting the same meetings as
  /// `enforceRetention`.
  func retentionPlan(protected: Set<String>, audioBudget: Int64) async
    -> RecordingRetention.Plan
  {
    await run { library in
      let ids = protected.union(library.needingAttention().map(\.id))
      do {
        return try RecordingRetention.plan(
          root: library.root, protected: ids, audioBudget: audioBudget)
      } catch {
        AppLog.event("retention.planFailed", error.localizedDescription)
        return RecordingRetention.Plan()
      }
    }
  }

  func removeCompletedRecordings(protected: Set<String>) async -> String? {
    await run { library in
      let completed = Set(
        library.meetings().filter {
          $0.status == .complete && library.transcriptURL(of: $0) != nil
        }.map(\.id)
      ).subtracting(protected)
      do {
        try RecordingRetention.removeCompletedAudio(root: library.root, completed: completed)
        return nil
      } catch {
        return error.localizedDescription
      }
    }
  }

  private func run<T: Sendable>(_ body: @escaping (MeetingLibrary) -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: body(self.library)) }
    }
  }
}

/// The main actor's view of the meetings folder. It never reads the folder itself: access checks,
/// scans and retention run in a `LibraryReader`, and the latest result is kept in `snapshot`.
/// While access is not granted, the snapshot stays empty and the check repeats every few seconds,
/// so the app continues on its own once the user allows access.
@MainActor
final class LibraryStore {
  private(set) var access: MeetingsFolderAccess = .checking
  private(set) var snapshot = LibrarySnapshot()
  private(set) var reader: LibraryReader
  private let makeReader: (URL) -> LibraryReader
  private let retryInterval: Duration
  private var generation = 0
  private var scanning = false
  private var scanAgain = false
  /// Runs once per folder when access is granted, with its first snapshot.
  var onReady: ((LibrarySnapshot) -> Void)?
  var onChange: (() -> Void)?

  init(
    root: URL, retryInterval: Duration = .seconds(3),
    makeReader: @escaping (URL) -> LibraryReader = { LibraryReader(root: $0) }
  ) {
    self.makeReader = makeReader
    self.retryInterval = retryInterval
    reader = makeReader(root)
  }

  var root: URL { reader.root }
  var isReady: Bool { access == .granted }

  /// Why meetings cannot be read or changed now, or nil once the folder is readable.
  var unavailableReason: String? {
    let folder = root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    switch access {
    case .granted: return nil
    case .checking:
      return "Waiting for access to the meetings folder \(folder). Allow access when macOS asks."
    case .loading(updating: true):
      return
        "Updating meetings from an earlier version of Meeting Notes. This can take a few minutes."
    case .loading(updating: false):
      return "Loading meetings from \(folder)."
    case .denied(let reason):
      return
        "Meeting Notes cannot read the meetings folder \(folder): \(reason) Allow it in System Settings > Privacy & Security > Files and Folders."
    }
  }

  /// Navigation can wait for the initial scan; a denied or stalled probe remains an error.
  func waitForAccess(timeout: Duration = .seconds(10)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !isReady, access.isReadable || access == .checking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    if let reason = unavailableReason { throw MeetingError(reason) }
  }

  /// Starts checking access to the folder; returns immediately.
  func open() {
    generation += 1
    let generation = generation
    let reader = reader
    access = .checking
    snapshot = LibrarySnapshot()
    scanAgain = false
    onChange?()
    AppLog.event("library.checkingAccess", reader.root.path)
    Task {
      while true {
        let access = await reader.access()
        guard generation == self.generation else { return }
        if access == .granted { break }
        if access != self.access {
          self.access = access
          AppLog.event("library.accessDenied", "\(access)")
          onChange?()
        }
        try? await Task.sleep(for: retryInterval)
        guard generation == self.generation else { return }
      }
      let updating = await reader.needsMigration()
      guard generation == self.generation else { return }
      self.access = .loading(updating: updating)
      onChange?()
      if updating {
        AppLog.event("library.updating", reader.root.path)
        await reader.migrate()
        guard generation == self.generation else { return }
      }
      let snapshot = await reader.snapshot()
      guard generation == self.generation else { return }
      self.access = .granted
      self.snapshot = snapshot
      AppLog.event("library.ready", "\(snapshot.meetings.count) meetings")
      onReady?(snapshot)
      onChange?()
    }
  }

  func setRoot(_ root: URL) {
    reader = makeReader(root)
    open()
  }

  /// Rescans in the background. Requests during a scan are coalesced into one more scan.
  func refresh() {
    guard isReady else { return }
    if scanning {
      scanAgain = true
      return
    }
    scanning = true
    let generation = generation
    let reader = reader
    Task {
      repeat {
        scanAgain = false
        let next = await reader.snapshot()
        guard generation == self.generation else { break }
        apply(next)
      } while scanAgain
      scanning = false
    }
  }

  /// A snapshot that includes every change made before the call, or the current one while the
  /// folder is not readable.
  func current() async -> LibrarySnapshot {
    guard isReady else { return snapshot }
    let generation = generation
    let next = await reader.snapshot()
    if generation == self.generation { apply(next) }
    return snapshot
  }

  /// Applies retention in the background. Reconstruction archives live outside the meetings
  /// folder, so turning off kept audio removes them even while the folder is not readable.
  func enforceRetention(protected: Set<String>, audioBudget: Int64, keepAudio: Bool) {
    guard isReady else {
      if !keepAudio { Task.detached { ReconstructionArchive.enforce(keepAudio: false) } }
      return
    }
    let reader = reader
    Task {
      await reader.enforceRetention(
        protected: protected, audioBudget: audioBudget, keepAudio: keepAudio)
      refresh()
    }
  }

  /// What retention would delete with these budgets, or an empty plan while the folder is not
  /// readable.
  func retentionPlan(protected: Set<String>, audioBudget: Int64) async
    -> RecordingRetention.Plan
  {
    guard isReady else { return RecordingRetention.Plan() }
    return await reader.retentionPlan(
      protected: protected, audioBudget: audioBudget)
  }

  private func apply(_ next: LibrarySnapshot) {
    guard next != snapshot else { return }
    snapshot = next
    onChange?()
  }
}

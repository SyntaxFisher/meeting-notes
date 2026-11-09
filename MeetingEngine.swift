import AVFoundation
import Foundation

/// Records meetings and transcribes them, one meeting record at a time. Each meeting moves
/// through `recording`, `saving`, `queued`, `transcribing` and `complete`, or ends up `failed` or
/// `interrupted` until the user retries or discards it. Every change is written to the meeting's
/// record first, so the files always describe the truth and a relaunch continues where the app
/// stopped. Transcription runs in a persistent serial queue, so a new recording can start while
/// earlier meetings wait or transcribe.
@MainActor
final class MeetingEngine {
  struct ActiveRecording {
    let id: String
    let recorder: NativeRecorder
    let automatic: Bool
  }

  private(set) var library: MeetingLibrary
  /// Records of meetings that are not complete, by id, as last written.
  private(set) var unfinished: [String: MeetingRecord] = [:]
  private(set) var active: ActiveRecording?
  private(set) var isStarting = false
  /// The recording whose capture is closing before it is saved.
  private(set) var stopping: MeetingRecord?
  private(set) var transcribingID: String?
  private var savingTasks: [String: Task<Void, Never>] = [:]
  private var queueTask: Task<Void, Never>?
  private let transcriber = NativeTranscriber()
  private let teams: TeamsMonitor
  private var startingCaptureFailure: Error?
  private var quitting = false

  var config: () -> AppConfig = { AppConfig() }
  /// The transcription helper; nil uses the one inside the app bundle.
  var transcriberExecutable: URL?
  /// The label for the microphone speaker of a meeting with this participant list.
  var localSpeakerName: (ParticipantRoster?) -> String = { _ in
    TranscriptDocument.localSpeakerName(configured: nil, teamsName: nil)
  }
  var onChange: (() -> Void)?
  var onEvent: ((LifecycleEvent, MeetingRecord, [String: Any]) -> Void)?
  /// A recording that failed to start because macOS denied a permission.
  var onPermissionDenied: ((MeetingPermission, Error) -> Void)?
  /// Applies retention, given the ids of unfinished meetings; nil applies it right here.
  var onRetention: ((Set<String>) -> Void)?

  init(library: MeetingLibrary, teams: TeamsMonitor) {
    self.library = library
    self.teams = teams
  }

  // MARK: State

  var recordingRecord: MeetingRecord? { active.flatMap { unfinished[$0.id] } }

  /// Meetings waiting for or in transcription, in the order they are processed.
  var queue: [MeetingRecord] {
    unfinished.values.filter { $0.status == .transcribing || $0.status == .queued }
      .sorted { lhs, rhs in
        if (lhs.status == .transcribing) != (rhs.status == .transcribing) {
          return lhs.status == .transcribing
        }
        return (lhs.queuedAt ?? lhs.startedAt) < (rhs.queuedAt ?? rhs.startedAt)
      }
  }

  var saving: [MeetingRecord] { unfinished.values.filter { $0.status == .saving } }

  /// Whether anything would be lost or interrupted by quitting or installing an update.
  var isBusy: Bool {
    active != nil || isStarting || stopping != nil || !savingTasks.isEmpty || !queue.isEmpty
  }

  /// Ids that retention must never remove, besides the meetings that need attention.
  var protectedIDs: Set<String> { Set(unfinished.keys) }

  // MARK: Launch

  /// Continues after a relaunch with the unfinished meetings that have a record file: meetings
  /// left recording become interrupted, saving meetings with saved audio and transcribing
  /// meetings return to the queue. Nothing is deleted.
  func recover(_ records: [MeetingRecord]) {
    for record in records where record.status != .complete {
      var next = record
      switch record.status {
      case .recording:
        next.status = .interrupted
        next.error =
          "Meeting Notes quit while this meeting was recording. Retry saves and transcribes what was captured."
        next.failedAt = Date()
      case .saving:
        if library.audioURL(of: record) != nil {
          next.status = .queued
        } else {
          next.status = .interrupted
          next.error =
            "Meeting Notes quit while saving this recording. Retry saves and transcribes what was captured."
          next.failedAt = Date()
        }
      case .transcribing:
        next.status = .queued
        next.stage = nil
        next.progress = nil
      case .queued, .failed, .interrupted, .untranscribed, .complete: break
      }
      if next.status == .queued, next.queuedAt == nil { next.queuedAt = record.startedAt }
      if next != record {
        write(next)
        AppLog.event("meeting.recovered", "\(record.id); \(record.status) -> \(next.status)")
        if next.status == .interrupted {
          onEvent?(.recordingInterrupted, next, ["previousStatus": record.status.rawValue])
        }
      }
      unfinished[record.id] = next
    }
    changed()
    pump()
  }

  // MARK: Recording

  /// Starts the microphone and Teams audio during a Teams meeting, otherwise device audio.
  func startRecording(
    title: String?, automatically: Bool
  ) async throws -> MeetingRecord {
    guard active == nil, !isStarting else {
      throw MeetingError("A recording is already running.")
    }
    isStarting = true
    changed()
    defer {
      isStarting = false
      changed()
    }
    try MeetingFiles.ensureDirectories()
    enforceRetention()
    teams.start()
    let teamsMeeting: TeamsMeetingPresence =
      automatically
      ? teams.currentState?.meetingPresence ?? .unknown
      : await teams.readState().meetingPresence
    let systemAudio = SystemAudioScope.forRecording(
      automatic: automatically, teamsMeeting: teamsMeeting)
    let now = Date()
    let id = MeetingFiles.id(
      startingAt: now, in: library.audios, transcriptDirectory: library.transcripts)
    var record = MeetingRecord(
      id: id,
      title: MeetingFiles.displayTitle(title ?? (systemAudio == .teams ? teams.meetingTitle : nil)),
      startedAt: now,
      status: .recording, trigger: automatically ? .automatic : .manual)
    record.source = MeetingSource(systemAudio)
    record.titleSource =
      record.title == nil ? .none : title == nil && systemAudio == .teams ? .teams : .user
    write(record)
    AppLog.event(
      "recording.systemAudio",
      "\(id); \(systemAudio.rawValue); teamsMeeting=\(teamsMeeting)"
    )
    let capture = library.captureURL(for: id)
    let recorder = NativeRecorder(directory: capture, systemAudio: systemAudio)
    startingCaptureFailure = nil
    recorder.onFailure = { [weak self, weak recorder] error in
      Task { @MainActor in
        guard let self, let recorder else { return }
        if self.isStarting, self.active == nil {
          self.startingCaptureFailure = error
        } else if self.active?.recorder === recorder {
          _ = try? await self.stopRecording(captureError: error)
        }
      }
    }
    if systemAudio == .teams, config().mirrorTeamsMute { teams.mirroredRecorder = recorder }
    do {
      try await recorder.start()
      if let startingCaptureFailure { throw startingCaptureFailure }
    } catch {
      teams.mirroredRecorder = nil
      try? await recorder.stop()
      handleStartFailure(record, error: error)
      throw error
    }
    record.source = recorder.meetingSource
    write(record)
    active = ActiveRecording(id: id, recorder: recorder, automatic: automatically)
    if systemAudio == .teams {
      teams.startRoster(in: capture, startedAt: now)
    }
    AppLog.event("recording.started", "\(id); automatic=\(automatically)")
    onEvent?(.recordingStarted, record, [:])
    changed()
    return record
  }

  private func handleStartFailure(_ record: MeetingRecord, error: Error) {
    let capture = library.captureURL(for: record.id)
    let captured = FileManager.default.fileExists(
      atPath: capture.appendingPathComponent("capture.json").path)
    if captured {
      markFailed(record.id, "Recording could not start: \(error.localizedDescription)")
    } else {
      try? FileManager.default.removeItem(at: capture)
      try? FileManager.default.removeItem(at: library.recordURL(for: record.id))
      unfinished[record.id] = nil
    }
    if let permission = PermissionAccess.deniedPermission(for: error) {
      onPermissionDenied?(permission, error)
    }
    AppLog.event("recording.startFailed", "\(record.id); \(error.localizedDescription)")
  }

  /// Uses the Teams meeting title for a recording that has none yet.
  func adoptTeamsTitle(_ title: String?) {
    guard let active, var record = unfinished[active.id], record.source == .teams,
      record.title == nil,
      let title = MeetingFiles.displayTitle(title)
    else { return }
    record.title = title
    record.titleSource = .teams
    write(record)
    changed()
  }

  func setRecordingTitle(_ title: String) throws -> MeetingRecord {
    guard let active, var record = unfinished[active.id] else {
      throw MeetingError("Nothing is recording. To retitle a finished meeting, pass its id.")
    }
    record.title = MeetingFiles.displayTitle(title)
    record.titleSource = record.title == nil ? .none : .user
    write(record)
    changed()
    return record
  }

  /// Stops the recording. Its audio is then saved and queued for transcription in the
  /// background, so another recording can start right away. With `discard`, the captured audio
  /// and the record move to the Trash instead.
  @discardableResult
  func stopRecording(discard: Bool = false, captureError: Error? = nil) async throws
    -> MeetingRecord
  {
    guard let current = active, var record = unfinished[current.id] else {
      throw MeetingError("Nothing is recording.")
    }
    active = nil
    stopping = record
    changed()
    teams.mirroredRecorder = nil
    await teams.stopRoster()
    var failure = captureError
    do { try await current.recorder.stop() } catch { failure = failure ?? error }
    stopping = nil
    record.endedAt = Date()
    if discard {
      try discardStoppedRecording(record, reason: "Discarded by the user.")
      return record
    }
    record.status = .saving
    write(record)
    AppLog.event("recording.stopped", record.id)
    onEvent?(
      .recordingStopped, record, failure.map { ["error": $0.localizedDescription] } ?? [:])
    if let failure, !hasCapturedAudio(record.id) {
      markFailed(record.id, "Recording stopped unexpectedly: \(failure.localizedDescription)")
      changed()
      return unfinished[record.id] ?? record
    }
    save(record.id)
    changed()
    return record
  }

  /// Saves before quitting: stops the recording and mixes its audio so the meeting stays queued.
  func prepareToQuit() async {
    quitting = true
    if active != nil { _ = try? await stopRecording() }
    for task in savingTasks.values { await task.value }
    queueTask?.cancel()
    transcriber.cancel()
    await queueTask?.value
  }

  // MARK: Saving

  private func hasCapturedAudio(_ id: String) -> Bool {
    FileManager.default.fileExists(
      atPath: library.captureURL(for: id).appendingPathComponent("capture.json").path)
  }

  /// Mixes the capture tracks into the meeting's audio file and queues it.
  private func save(_ id: String) {
    guard savingTasks[id] == nil else { return }
    savingTasks[id] = Task { [weak self] in
      await self?.mix(id)
      self?.savingTasks[id] = nil
      self?.changed()
      self?.pump()
    }
  }

  private func mix(_ id: String) async {
    guard var record = unfinished[id] else { return }
    let capture = library.captureURL(for: id)
    let destination = MeetingFiles.audio(for: id, in: library.audios)
    do {
      if !FileManager.default.fileExists(atPath: destination.path) {
        guard hasCapturedAudio(id) else {
          throw MeetingError("No audio was captured. Check the recording permissions.")
        }
        let partial = capture.appendingPathComponent("mixed.m4a")
        if FileManager.default.fileExists(atPath: partial.path) {
          try FileManager.default.removeItem(at: partial)
        }
        try await Task.detached {
          try NativeRecorder.mix(directory: capture, destination: partial)
        }.value
        try FileManager.default.moveItem(at: partial, to: destination)
      }
      guard let current = unfinished[id] else { return }
      record = current
      record.audioFile = destination.lastPathComponent
      if let duration = try? NativeTranscriber.duration(of: destination) {
        record.durationSeconds = MeetingRecord.seconds(duration)
        record.endedAt = record.startedAt.addingTimeInterval(duration)
      }
      record.status = .queued
      record.queuedAt = Date()
      record.error = nil
      record.failedAt = nil
      try persist(record)
      AppLog.event("capture.saved", destination.path)
      archiveCaptureForDevelopment(capture, id: id)
      enforceRetention()
      onEvent?(.transcriptionQueued, record, ["position": queue.count])
    } catch {
      markFailed(id, "Saving the recording failed: \(error.localizedDescription)")
    }
  }

  /// Copies the separate capture tracks to the `captureArchiveDirectory` development default so
  /// live recordings can be transcribed again offline.
  private func archiveCaptureForDevelopment(_ directory: URL, id: String) {
    guard let archive = UserDefaults.standard.string(forKey: "captureArchiveDirectory") else {
      return
    }
    let target = URL(fileURLWithPath: archive, isDirectory: true).appendingPathComponent(id)
    guard FileManager.default.fileExists(atPath: directory.path),
      !FileManager.default.fileExists(atPath: target.path)
    else { return }
    do {
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: directory, to: target)
      AppLog.event("capture.archived", target.path)
    } catch { AppLog.event("capture.archiveFailed", error.localizedDescription) }
  }

  // MARK: Transcription queue

  private func pump() {
    guard queueTask == nil, !quitting, queue.contains(where: { $0.status == .queued }) else {
      return
    }
    queueTask = Task { [weak self] in
      while let self, !Task.isCancelled, !self.quitting,
        let next = self.queue.first(where: { $0.status == .queued })
      {
        await self.transcribe(next.id)
      }
      self?.queueTask = nil
    }
  }

  private func transcribe(_ id: String) async {
    guard var record = unfinished[id] else { return }
    guard let audio = library.audioURL(of: record) else {
      markFailed(id, "The saved audio is missing, so the meeting cannot be transcribed.")
      return
    }
    transcribingID = id
    defer {
      transcribingID = nil
      transcriber.onProgress = nil
      changed()
    }
    record.status = .transcribing
    record.stage = "Starting the transcription engine"
    record.progress = nil
    transcriber.onProgress = { [weak self] stage in
      guard let self, var current = self.unfinished[id], current.status == .transcribing else {
        return
      }
      let progress = TranscriptionProgress(helperStage: stage)
      current.stage = progress.description
      current.progress = progress.fraction
      self.write(current)
      self.changed()
    }
    let capture = library.captureURL(for: id)
    let tracks = FileManager.default.fileExists(atPath: capture.path) ? capture : nil
    let destination = MeetingFiles.transcript(for: id, in: library.transcripts)
    do {
      try persist(record)
      onEvent?(.transcriptionStarted, record, [:])
      changed()
      let text: String
      if FileManager.default.fileExists(atPath: destination.path) {
        text = try String(contentsOf: destination, encoding: .utf8)
        record.segments = MeetingLibrary.parseTranscript(text)
        record.speakers = MeetingRecord.speakers(for: record.segments, keeping: record.speakers)
      } else {
        AppLog.event(
          "transcription.begin",
          "\(audio.path); tracks=\(tracks == nil ? "mixed" : "separate")")
        let result = try await transcriber.transcribe(
          file: audio, capture: tracks, executable: transcriberExecutable)
        try Task.checkCancellation()
        guard let current = unfinished[id] else { return }
        record = current
        let roster = tracks.flatMap {
          try? JSONDecoder().decode(
            ParticipantRoster.self,
            from: Data(contentsOf: $0.appendingPathComponent("participants.json")))
        }
        let speaking = tracks.flatMap(SpeakingTimeline.load(fromCapture:))
        text = TranscriptDocument.compose(
          result, into: &record, localName: localSpeakerName(roster), roster: roster,
          speaking: speaking)
        try MeetingFiles.publish(Data(text.utf8), to: destination)
      }
      record.transcriptFile = destination.lastPathComponent
      record.status = .complete
      record.stage = nil
      record.progress = nil
      record.queuedAt = nil
      record.error = nil
      record.failedAt = nil
      try persist(record)
      if !config().keepAudio {
        do {
          try FileManager.default.removeItem(at: audio)
          record.audioFile = nil
          try persist(record)
        } catch {
          AppLog.event("audio.cleanup.failed", "\(id): \(error.localizedDescription)")
        }
      }
      unfinished[id] = nil
      if let tracks { try? FileManager.default.removeItem(at: tracks) }
      AppLog.event("transcription.saved", destination.path)
      enforceRetention()
      onEvent?(.transcriptReady, record, [:])
    } catch _ where unfinished[id] == nil {
      AppLog.event("transcription.cancelled", "\(id); discarded")
    } catch is CancellationError {
      requeue(id)
    } catch is NoSpeechDetected where (record.durationSeconds ?? 0) < 60 {
      do {
        try discardStoppedRecording(
          record, reason: "No speech was detected in a recording under one minute.")
      } catch {
        if let failed = unfinished[id] { onEvent?(.transcriptionFailed, failed, [:]) }
      }
    } catch {
      if Task.isCancelled || quitting {
        requeue(id)
      } else {
        markFailed(id, error.localizedDescription)
        if let failed = unfinished[id] { onEvent?(.transcriptionFailed, failed, [:]) }
      }
    }
  }

  private func requeue(_ id: String) {
    guard var record = unfinished[id] else { return }
    record.status = .queued
    record.stage = nil
    record.progress = nil
    write(record)
  }

  // MARK: Retry and discard

  func discardStoppedRecording(_ record: MeetingRecord, reason: String) throws {
    do {
      try library.moveToTrash(record.id)
    } catch {
      unfinished[record.id] = record
      markFailed(record.id, "Discarding failed: \(error.localizedDescription)")
      changed()
      throw error
    }
    unfinished[record.id] = nil
    AppLog.event("recording.discarded", record.id)
    onEvent?(.recordingDiscarded, record, ["reason": reason])
    changed()
  }

  /// Queues a failed, interrupted or untranscribed meeting again, re-saving its audio first
  /// when only the capture tracks exist.
  @discardableResult
  func retry(_ id: String) throws -> MeetingRecord {
    var record = try library.load(id)
    guard record.status.needsAttention else {
      throw MeetingError(
        "\"\(record.id)\" is \(record.status.rawValue); only failed, interrupted or untranscribed meetings can be retried."
      )
    }
    let work = library.work(for: record)
    record.error = nil
    record.failedAt = nil
    if let audio = work.audio {
      record.audioFile = audio.lastPathComponent
      record.status = .queued
      record.queuedAt = Date()
      try persist(record)
      onEvent?(.transcriptionQueued, record, ["position": queue.count, "retry": true])
      pump()
    } else if work.hasCapturedAudio {
      record.status = .saving
      try persist(record)
      save(id)
    } else {
      throw MeetingError(
        "Nothing can be retried: no audio was saved for \"\(record.id)\". Discard it instead.")
    }
    AppLog.event("meeting.retried", id)
    changed()
    return record
  }

  /// Moves an unfinished meeting's files (audio, capture tracks and record) to the Trash. A
  /// meeting being transcribed stops its transcription; one being saved leaves the queue at
  /// once and moves to the Trash when its audio is mixed.
  @discardableResult
  func discard(_ id: String) async throws -> MeetingRecord {
    let record = try unfinished[id] ?? library.load(id)
    switch record.status {
    case .failed, .interrupted, .untranscribed, .queued, .saving, .transcribing: break
    case .recording:
      throw MeetingError("\"\(id)\" is recording. Stop and discard the recording instead.")
    case .complete:
      throw MeetingError("\"\(id)\" has a transcript. Delete the meeting instead.")
    }
    unfinished[id] = nil
    changed()
    if transcribingID == id { transcriber.cancel() }
    if let saving = savingTasks[id] { await saving.value }
    let trashed: [URL]
    do { trashed = try library.moveToTrash(id) } catch {
      unfinished[id] = record
      markFailed(id, "Discarding failed: \(error.localizedDescription)")
      changed()
      throw error
    }
    AppLog.event("meeting.discarded", "\(id); \(trashed.map(\.lastPathComponent))")
    onEvent?(.meetingDiscarded, record, ["trashed": trashed.map(\.path)])
    changed()
    return record
  }

  /// Moves a finished meeting's files to the Trash.
  @discardableResult
  func delete(_ id: String) throws -> MeetingRecord {
    let record = try unfinished[id] ?? library.load(id)
    guard record.status == .complete else {
      throw MeetingError(
        "\"\(id)\" is \(record.status.rawValue). Discard unfinished meetings instead.")
    }
    let trashed = try library.moveToTrash(id)
    AppLog.event("meeting.deleted", "\(id); \(trashed.map(\.lastPathComponent))")
    onEvent?(.meetingDeleted, record, ["trashed": trashed.map(\.path)])
    changed()
    return record
  }

  @discardableResult
  func deleteAllMeetings() throws -> Int {
    guard !isBusy else {
      throw MeetingError(
        "Wait until recording and transcription finish before deleting all meetings.")
    }
    let records = library.meetings()
    guard !records.contains(where: { $0.status.isInProgress }) else {
      throw MeetingError("Some meetings are still being processed. Try again once they finish.")
    }
    defer { changed() }
    for record in records {
      try library.moveToTrash(record.id)
      unfinished[record.id] = nil
    }
    AppLog.event("meetings.deletedAll", "count=\(records.count)")
    return records.count
  }

  // MARK: Helpers

  private func markFailed(_ id: String, _ message: String) {
    guard var record = unfinished[id] else { return }
    record.status = .failed
    record.error = message
    record.failedAt = Date()
    record.stage = nil
    record.progress = nil
    write(record)
    AppLog.event("meeting.failed", "\(id); \(message)")
    if record.transcriptFile == nil, record.audioFile == nil {
      onEvent?(.recordingFailed, record, ["error": message])
    }
  }

  private func persist(_ record: MeetingRecord) throws {
    try library.save(record)
    if record.status != .complete { unfinished[record.id] = record }
  }

  private func write(_ record: MeetingRecord) {
    do { try persist(record) } catch {
      if record.status != .complete { unfinished[record.id] = record }
      AppLog.event("record.saveFailed", "\(record.id); \(error.localizedDescription)")
    }
  }

  func enforceRetention() {
    if let onRetention {
      onRetention(protectedIDs)
      return
    }
    let config = config()
    do {
      try RecordingRetention.enforce(
        root: library.root,
        protected: protectedIDs.union(library.needingAttention().map(\.id)),
        audioBudget: config.retention.audioBytes)
    } catch {
      AppLog.event("retention.failed", error.localizedDescription)
    }
  }

  private func changed() { onChange?() }
}

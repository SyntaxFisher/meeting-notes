import Foundation

/// Device-free checks for the meeting lifecycle: records, recovery after a relaunch, the
/// persistent transcription queue, several failures at once with independent retry and discard,
/// the command layer's validation, and retention by meeting id. A shell script stands in for the
/// transcription helper.
enum MeetingSmoke {
  @MainActor
  static func run(root: URL) async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    let meetings = root.appendingPathComponent("meetings", isDirectory: true)
    try manager.createDirectory(at: trash, withIntermediateDirectories: true)
    let library = MeetingLibrary(root: meetings)
    library.trash = { file in
      try manager.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
    }
    try manager.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: library.transcripts, withIntermediateDirectories: true)

    try testScanning(library)
    print("Meeting library: records, legacy transcripts, leftover audio and captures: OK")
    let helper = try fakeHelper(in: root)
    try await testQueue(library, helper: helper, root: root, trash: trash)
    print("Queue: recovery after relaunch, serial order, failures, retry and discard: OK")
    try await testCompletionPersistenceFailure(
      root.appendingPathComponent("persistence"), helper: helper)
    try await testDiscardFailure(root.appendingPathComponent("discard-failure"))
    print("Lifecycle writes: failed retries and completion preserve captured audio: OK")
    try await testTemporaryAudio(root.appendingPathComponent("temporary-audio"))
    try await testAudioRemoval(root.appendingPathComponent("remove-audio"))
    try testDeleteAll(root.appendingPathComponent("delete-all"))
    try testRetention(root.appendingPathComponent("retention"))
    print(
      "Retention by meeting id, with extra files, audio, protected meetings and its preview: OK")
  }

  static func date(_ text: String) -> Date { MeetingFiles.date(fromStem: text)! }

  @discardableResult
  static func write(
    _ library: MeetingLibrary, _ id: String, _ status: MeetingStatus,
    title: String? = nil, audio: Bool = false, queuedAt: Date? = nil, error: String? = nil
  ) throws -> MeetingRecord {
    var record = MeetingRecord(id: id, title: title, startedAt: date(id), status: status)
    record.queuedAt = queuedAt
    record.error = error
    if audio {
      let file = MeetingFiles.audio(for: record.fileStem, in: library.audios)
      try Data(repeating: 7, count: 64).write(to: file)
      record.audioFile = file.lastPathComponent
      record.durationSeconds = 120
    }
    try library.save(record)
    return record
  }

  static func testScanning(_ library: MeetingLibrary) throws {
    let manager = FileManager.default
    try "[00:00:01] Speaker 1: Legacy hello\n".write(
      to: library.transcripts.appendingPathComponent("2026-10-01 09.00 Old Sync.txt"),
      atomically: true, encoding: .utf8)
    try Data(repeating: 1, count: 16).write(
      to: library.audios.appendingPathComponent("2026-10-02 09.00 Orphan.m4a"))
    try manager.createDirectory(
      at: library.captureURL(for: "2026-10-03 09.00"), withIntermediateDirectories: true)
    try #"{"title":"not ours"}"#.write(
      to: library.transcripts.appendingPathComponent("2026-10-04 09.00.json"), atomically: true,
      encoding: .utf8)
    try #"{"speakers":[]}"#.write(
      to: library.transcripts.appendingPathComponent("2026-10-01 09.00 Old Sync.json"),
      atomically: true, encoding: .utf8)
    let all = library.meetings()
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    precondition(byID["2026-10-01 09.00"]?.status == .complete)
    precondition(byID["2026-10-01 09.00"]?.title == "Old Sync")
    precondition(byID["2026-10-02 09.00"]?.status == .untranscribed)
    precondition(byID["2026-10-02 09.00"]?.audioFile == "2026-10-02 09.00 Orphan.m4a")
    precondition(byID["2026-10-03 09.00"]?.status == .interrupted)
    precondition(byID["2026-10-04 09.00"] == nil, "Foreign JSON is not a meeting")
    precondition(library.needingAttention().map(\.id) == ["2026-10-02 09.00", "2026-10-03 09.00"])
    precondition(library.work(for: byID["2026-10-02 09.00"]!).canRetry)
    precondition(!library.work(for: byID["2026-10-03 09.00"]!).canRetry)
    do {
      try library.save(MeetingRecord(id: "2026-10-04 09.00", startedAt: Date(), status: .failed))
      preconditionFailure("A foreign file must not be replaced")
    } catch {}
    try manager.removeItem(at: library.transcripts.appendingPathComponent("2026-10-04 09.00.json"))
    let encoded = try JSONCoding.encoder().encode(byID["2026-10-01 09.00"]!)
    let decoded = try JSONCoding.decoder().decode(MeetingRecord.self, from: encoded)
    precondition(decoded == byID["2026-10-01 09.00"])
    var future = String(decoding: encoded, as: UTF8.self)
    future = future.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
    precondition(
      (try? JSONCoding.decoder().decode(MeetingRecord.self, from: Data(future.utf8))) == nil)
    precondition(
      Set(library.files(of: "2026-10-01 09.00").map(\.lastPathComponent))
        == ["2026-10-01 09.00 Old Sync.txt", "2026-10-01 09.00 Old Sync.json"])
  }

  /// A stand-in for MeetingTranscriber: reports one stage, then writes two segments, or fails
  /// while `fail` exists. While `slow` exists it takes 30 seconds. Every run appends the audio file name to `order.log`.
  static func fakeHelper(in root: URL) throws -> URL {
    let script = root.appendingPathComponent("fake-transcriber")
    let fail = root.appendingPathComponent("fail")
    let slow = root.appendingPathComponent("slow")
    let log = root.appendingPathComponent("order.log")
    try """
    #!/bin/sh
    printf '%s\\n' "$(basename "$1")" >> '\(log.path)'
    printf '{"stage":"Transcribing part 1/2"}' > "$3"
    sleep 0.2
    if [ -e '\(slow.path)' ]; then sleep 30; fi
    if [ -e '\(fail.path)' ]; then
      printf '{"stage":"Failed","error":"Fake engine failure"}' > "$3"
      exit 1
    fi
    printf '{"mode":"mixed","engine":"fixture","duration":4,"segments":[{"start":0,"end":2,"source":"mix","speaker":"a","text":"Hello from %s"},{"start":2,"end":4,"source":"mix","speaker":"b","text":"Second voice"}]}' "$(basename "$1")" > "$2"
    printf '{"stage":"Complete"}' > "$3"
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  @MainActor
  static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 15) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    precondition(condition(), "Timed out waiting for the engine")
  }

  @MainActor
  static func testQueue(_ library: MeetingLibrary, helper: URL, root: URL, trash: URL) async throws
  {
    let manager = FileManager.default
    let t0 = date("2026-11-05 08.00")
    try write(library, "2026-11-05 09.00", .transcribing, title: "First", audio: true, queuedAt: t0)
    try write(
      library, "2026-11-05 10.00", .queued, title: "Second", audio: true,
      queuedAt: t0.addingTimeInterval(60))
    try write(library, "2026-11-05 11.00", .recording, title: "Crashed")
    try manager.createDirectory(
      at: library.captureURL(for: "2026-11-05 11.00"), withIntermediateDirectories: true)
    try write(library, "2026-11-05 12.00", .saving, audio: true)
    try write(library, "2026-11-05 13.00", .failed, error: "Saving failed")

    var events: [(LifecycleEvent, String)] = []
    let engine = MeetingEngine(library: library, teams: TeamsMonitor())
    engine.transcriberExecutable = helper
    engine.localSpeakerName = { _ in "Jona" }
    engine.onEvent = { event, record, _ in events.append((event, record.id)) }
    engine.recover(library.recoverable(library.meetings()))
    let recovered = Dictionary(uniqueKeysWithValues: library.meetings().map { ($0.id, $0.status) })
    precondition(recovered["2026-11-05 11.00"] == .interrupted)
    precondition(recovered["2026-11-05 13.00"] == .failed)
    precondition(engine.isBusy)
    precondition(engine.protectedIDs.isSuperset(of: ["2026-11-05 10.00", "2026-11-05 13.00"]))
    await waitUntil { engine.queue.isEmpty }
    let order = try String(contentsOf: root.appendingPathComponent("order.log"), encoding: .utf8)
    precondition(
      order == "2026-11-05 09.00 First.m4a\n2026-11-05 10.00 Second.m4a\n2026-11-05 12.00.m4a\n",
      "Unexpected order: \(order)")
    let first = try library.load("2026-11-05 09.00")
    precondition(first.status == .complete && first.segments.count == 2)
    precondition(first.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
    precondition(first.stage == nil && first.queuedAt == nil)
    let text = try String(contentsOf: library.transcriptURL(of: first)!, encoding: .utf8)
    precondition(text.contains("[00:00:00] Speaker 1: Hello from 2026-11-05 09.00 First.m4a"))
    precondition(first.transcriptFile == "2026-11-05 09.00 First.txt")
    precondition(
      events.filter { $0.0 == .transcriptReady }.map(\.1)
        == ["2026-11-05 09.00", "2026-11-05 10.00", "2026-11-05 12.00"])
    precondition(events.contains { $0 == (.recordingInterrupted, "2026-11-05 11.00") })

    // Two failures at once, each retried and discarded on its own.
    try Data().write(to: root.appendingPathComponent("fail"))
    try write(library, "2026-11-05 14.00", .failed, title: "Alpha", audio: true, error: "Old")
    try write(library, "2026-11-05 15.00", .failed, title: "Beta", audio: true, error: "Old")
    try engine.retry("2026-11-05 14.00")
    try engine.retry("2026-11-05 15.00")
    await waitUntil { engine.queue.isEmpty }
    for id in ["2026-11-05 14.00", "2026-11-05 15.00"] {
      let failed = try library.load(id)
      precondition(failed.status == .failed && failed.error == "Fake engine failure")
      precondition(failed.failedAt != nil && library.work(for: failed).canRetry)
    }
    precondition(events.filter { $0.0 == .transcriptionFailed }.count == 2)

    let config = ConfigStore(file: root.appendingPathComponent("config.json"))
    config.load()
    var permissions = PermissionSnapshot(
      microphone: true, systemAudioRequested: true, accessibility: true)
    var openedLinks: [MeetingLink] = []
    let commands = CommandCenter(
      engine: engine, config: config, teams: TeamsMonitor(),
      context: CommandCenter.Context(
        permissions: { permissions }, requestingPermissions: { false },
        updateInstalling: { false }, refreshPermissions: {},
        openMeeting: { openedLinks.append($0) }))
    commands.events = EventLog(file: root.appendingPathComponent("events.jsonl"))
    func refusal(_ command: MeetingCommand) async -> String {
      guard case .failure(let error) = await commands.perform(command, source: .socket) else {
        preconditionFailure("\(command) should be refused")
      }
      return error.message
    }
    let meetingLink = MeetingLink(meetingID: "2026-11-05 09.00")
    let opened = await commands.handle(
      ControlRequest(command: "open_meeting", arguments: ["url": .string(meetingLink.string)]))
    precondition(opened.ok && opened.meetingId == meetingLink.meetingID)
    precondition(openedLinks == [meetingLink])
    for url in [
      "https://example.com", "meetingnotes://meeting/missing", meetingLink.string + "?p=s999",
      meetingLink.string + "?t=999999", "meetingnotes://start",
    ] {
      let refused = await commands.handle(
        ControlRequest(command: "open_meeting", arguments: ["url": .string(url)]))
      precondition(!refused.ok)
    }
    precondition(openedLinks == [meetingLink], "Invalid targets must not navigate")
    let ambiguous = await refusal(.retry(id: nil))
    precondition(ambiguous.contains("meetings need attention; pass the id"), ambiguous)
    let discardAmbiguous = await refusal(.discard(id: nil))
    precondition(discardAmbiguous.contains("pass the id"))
    let stop = await refusal(.stop)
    precondition(stop == "Nothing is recording.")
    let discardComplete = await refusal(.discard(id: "2026-11-05 09.00"))
    precondition(discardComplete.contains("Delete the meeting"))
    let retryComplete = await refusal(.retry(id: "2026-11-05 09.00"))
    precondition(retryComplete.contains("only failed"))
    permissions.accessibility = false
    precondition(commands.startBlockedReason == nil)
    precondition(
      commands.startBlockedReason(automatically: true)?.contains("Accessibility")
        == true)
    permissions.systemAudioRequested = false
    precondition(commands.startBlockedReason?.contains("System Audio") == true)
    let automaticStatus = await commands.status()
    precondition(!automaticStatus.canStartRecording)
    precondition(automaticStatus.missingPermissions == [MeetingPermission.systemAudio.rawValue])
    permissions.microphone = false
    let start = await refusal(.start(title: nil))
    precondition(start.contains("Missing permissions: Microphone, System Audio"))
    precondition(!start.contains("Accessibility"))
    permissions.microphone = true
    permissions.systemAudioRequested = true
    permissions.accessibility = true
    precondition(commands.startBlockedReason == nil, "Queued work never blocks a recording")
    for source: JSONValue in ["auto", "microphone", "us.zoom.xos", .null, .number(42)] {
      let response = await commands.handle(
        ControlRequest(command: "start", arguments: ["source": source]))
      precondition(
        !response.ok && response.message == "Recording sources are selected automatically.")
    }
    precondition(engine.active == nil && !engine.isStarting)
    let log = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
    precondition(log.contains("\"command.rejected\"") && log.contains("\"source\":\"socket\""))

    try manager.removeItem(at: root.appendingPathComponent("fail"))
    let external = MeetingLibrary(root: library.root)
    try external.updateMeeting(
      "2026-11-05 14.00", title: .some("Alpha reviewed"), expectedRevision: 0)
    guard
      case .success(let retried) = await commands.perform(
        .retry(id: "2026-11-05 14.00"), source: .panel)
    else { preconditionFailure("Retry is accepted") }
    precondition(retried.meeting?.status == .queued)
    await waitUntil { engine.queue.isEmpty }
    let alpha = try library.load("2026-11-05 14.00")
    let beta = try library.load("2026-11-05 15.00")
    precondition(alpha.status == .complete && beta.status == .failed)
    precondition(alpha.title == "Alpha reviewed" && alpha.revision == 1)
    precondition(alpha.audioFile == "2026-11-05 14.00 Alpha.m4a")
    guard case .success = await commands.perform(.delete(id: "2026-11-05 15.00"), source: .socket)
    else { preconditionFailure("Discard is accepted") }
    precondition((try? library.load("2026-11-05 15.00")) == nil)
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("2026-11-05 15.00.json").path))
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("2026-11-05 15.00 Beta.m4a").path))
    do {
      try engine.retry("2026-11-05 13.00")
      preconditionFailure("Without audio there is nothing to retry")
    } catch {
      precondition(error.localizedDescription.contains("Discard it instead"))
    }
    let single = await commands.perform(.retry(id: nil), source: .url)
    if case .success = single { preconditionFailure("Several meetings still need attention") }
    try await engine.discard("2026-11-05 13.00")
    try await engine.discard("2026-11-05 11.00")
    try await engine.discard("2026-10-03 09.00")
    precondition(library.needingAttention().map(\.id) == ["2026-10-02 09.00"])
    guard case .success(let only) = await commands.perform(.retry(id: nil), source: .url)
    else { preconditionFailure("The only meeting that needs attention can be retried") }
    precondition(only.meeting?.id == "2026-10-02 09.00")
    await waitUntil { engine.queue.isEmpty }
    let orphan = try library.load("2026-10-02 09.00")
    precondition(orphan.status == .complete && orphan.title == "Orphan")
    precondition(
      library.transcriptURL(of: orphan)?.lastPathComponent == "2026-10-02 09.00 Orphan.txt")

    guard case .success = await commands.perform(.delete(id: "2026-11-05 09.00"), source: .library)
    else { preconditionFailure("Delete is accepted") }
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("2026-11-05 09.00 First.txt").path))
    precondition(events.contains { $0 == (.meetingDeleted, "2026-11-05 09.00") })
    guard
      case .success = await commands.perform(
        .renameSpeakers(id: "Second", names: ["1": "Ada"]), source: .socket)
    else { preconditionFailure("Rename is accepted") }
    let second = try library.load("2026-11-05 10.00")
    precondition(second.speakers[0].displayName == "Ada")
    guard
      case .success = await commands.perform(
        .updateSettings(SettingsChange(autoRecordTeamsMeetings: false)), source: .socket)
    else { preconditionFailure("Settings are accepted") }
    precondition(!config.config.autoRecordTeamsMeetings)
    let onDisk = try AppConfig.read(from: config.file)
    precondition(!onDisk.autoRecordTeamsMeetings)
    let refused = await commands.handle(
      ControlRequest(
        command: "set_settings",
        arguments: ["retention_audio_bytes": .number(0)]))
    precondition(!refused.ok && config.config.retention.audioBytes == 10_000_000_000)
    let limited = await commands.handle(
      ControlRequest(
        command: "set_settings",
        arguments: [
          "retention_audio_bytes": .number(5e9)
        ]))
    precondition(limited.ok && limited.status?.settings.retentionAudioBytes == 5_000_000_000)
    let limits = try AppConfig.read(from: config.file).retention
    precondition(limits.audioBytes == 5_000_000_000)
    // Discarding a meeting while it transcribes stops the engine and publishes nothing.
    try Data().write(to: root.appendingPathComponent("slow"))
    try write(library, "2026-11-05 16.00", .failed, title: "Gamma", audio: true, error: "Old")
    try engine.retry("2026-11-05 16.00")
    await waitUntil { engine.queue.first?.stage == "Transcribing part 1 of 2" }
    try write(library, "2026-11-05 16.30", .failed, title: "Queued deletion", audio: true)
    try engine.retry("2026-11-05 16.30")
    precondition(engine.queue.contains { $0.id == "2026-11-05 16.30" && $0.status == .queued })
    guard case .success = await commands.perform(.delete(id: "2026-11-05 16.30"), source: .socket)
    else { preconditionFailure("Deleting queued work is accepted") }
    precondition((try? library.load("2026-11-05 16.30")) == nil)
    precondition(!engine.queue.contains { $0.id == "2026-11-05 16.30" })
    let discardStarted = Date()
    guard case .success = await commands.perform(.delete(id: "2026-11-05 16.00"), source: .socket)
    else { preconditionFailure("Discarding a transcribing meeting is accepted") }
    precondition(engine.queue.isEmpty)
    await waitUntil { engine.transcribingID == nil }
    precondition(Date().timeIntervalSince(discardStarted) < 10, "The engine stops right away")
    precondition((try? library.load("2026-11-05 16.00")) == nil)
    precondition(
      !manager.fileExists(
        atPath: library.transcripts.appendingPathComponent("2026-11-05 16.00 Gamma.txt").path))
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("2026-11-05 16.00 Gamma.m4a").path))
    precondition(events.contains { $0 == (.meetingDiscarded, "2026-11-05 16.00") })
    precondition(!events.contains { $0 == (.transcriptionFailed, "2026-11-05 16.00") })
    try manager.removeItem(at: root.appendingPathComponent("slow"))

    let status = await commands.status()
    precondition(status.running && status.queue.isEmpty && status.recording == nil)
    precondition(status.lastTranscriptId == "2026-11-05 14.00")
  }

  @MainActor
  static func testDiscardFailure(_ root: URL) async throws {
    let manager = FileManager.default
    let library = MeetingLibrary(root: root)
    try manager.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: library.transcripts, withIntermediateDirectories: true)
    let trash = root.appendingPathComponent("Trash")
    try manager.createDirectory(at: trash, withIntermediateDirectories: true)
    for (index, state) in [MeetingStatus.recording, .transcribing].enumerated() {
      let record = try write(
        library, "2026-11-05 19.0\(index)", state, title: "Discard failure", audio: true)
      let audio = library.audioURL(of: record)!
      let original = try Data(contentsOf: audio)
      let engine = MeetingEngine(library: library, teams: TeamsMonitor())
      var discarded = false
      engine.onEvent = { event, _, _ in
        if event == .recordingDiscarded { discarded = true }
      }
      library.trash = { _ in throw MeetingError("Trash is unavailable") }
      do {
        try engine.discardStoppedRecording(record, reason: "Discard fixture")
        preconditionFailure("Failed discard must report failure")
      } catch {}
      precondition(!discarded && engine.unfinished[record.id]?.status == .failed)
      let failed = try library.load(record.id)
      precondition(failed.status == .failed && failed.error?.contains("Discarding failed") == true)
      let remaining = try Data(contentsOf: audio)
      precondition(remaining == original)
      library.trash = { file in
        try manager.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
      }
      try await engine.discard(record.id)
      precondition(engine.unfinished[record.id] == nil)
      precondition(!manager.fileExists(atPath: audio.path))
    }
  }

  @MainActor
  static func testCompletionPersistenceFailure(_ root: URL, helper: URL) async throws {
    let manager = FileManager.default
    let library = MeetingLibrary(root: root)
    try manager.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: library.transcripts, withIntermediateDirectories: true)
    let record = try write(
      library, "2026-11-05 18.00", .failed, title: "Save failure", audio: true)
    let capture = library.captureURL(for: record.id)
    try manager.createDirectory(at: capture, withIntermediateDirectories: true)
    let captureBytes = Data("original captured audio".utf8)
    let track = capture.appendingPathComponent("microphone.wav")
    try captureBytes.write(to: track)
    let engine = MeetingEngine(library: library, teams: TeamsMonitor())
    engine.transcriberExecutable = helper
    engine.recover([record])

    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.transcripts.path)
    defer {
      try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.transcripts.path)
    }
    do {
      try engine.retry(record.id)
      preconditionFailure("A retry must persist its queued state before starting work")
    } catch {}
    precondition(engine.queue.isEmpty && engine.unfinished[record.id]?.status == .failed)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.transcripts.path)

    let foreignData = Data(#"{"owner":"another application"}"#.utf8)
    var injectionError: Error?
    var ready = false
    engine.onEvent = { event, _, _ in
      if event == .transcriptionStarted {
        do { try foreignData.write(to: library.recordURL(for: record.id), options: .atomic) } catch
        { injectionError = error }
      }
      if event == .transcriptReady { ready = true }
    }
    try engine.retry(record.id)
    await waitUntil { engine.queue.isEmpty && engine.transcribingID == nil }
    if let injectionError { throw injectionError }
    precondition(engine.unfinished[record.id]?.status == .failed && !ready)
    let savedTrack = try Data(contentsOf: track)
    let savedRecord = try Data(contentsOf: library.recordURL(for: record.id))
    precondition(savedTrack == captureBytes && savedRecord == foreignData)
    precondition(manager.fileExists(atPath: library.audioURL(of: record)!.path))
    precondition(
      manager.fileExists(
        atPath: MeetingFiles.transcript(for: record.fileStem, in: library.transcripts).path))
  }

  @MainActor
  static func testTemporaryAudio(_ root: URL) async throws {
    let manager = FileManager.default
    let library = MeetingLibrary(root: root)
    try manager.createDirectory(at: library.audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: library.transcripts, withIntermediateDirectories: true)
    let helper = try fakeHelper(in: root)
    var config = AppConfig()
    config.keepAudio = false
    let engine = MeetingEngine(library: library, teams: TeamsMonitor())
    engine.config = { config }
    engine.transcriberExecutable = helper
    let failed = try write(library, "2026-11-07 09.00", .queued, audio: true)
    let audio = library.audioURL(of: failed)!
    try Data().write(to: root.appendingPathComponent("fail"))
    engine.recover([failed])
    await waitUntil { engine.queue.isEmpty && engine.transcribingID == nil }
    precondition(manager.fileExists(atPath: audio.path))
    let failedRecord = try library.load(failed.id)
    precondition(failedRecord.status == .failed)
    try manager.removeItem(at: root.appendingPathComponent("fail"))
    try engine.retry(failed.id)
    await waitUntil { engine.queue.isEmpty && engine.transcribingID == nil }
    let completed = try library.load(failed.id)
    precondition(completed.status == .complete && !completed.segments.isEmpty)
    precondition(completed.audioFile == nil && library.audioURL(of: completed) == nil)
    precondition(!manager.fileExists(atPath: audio.path))
    precondition(library.transcriptURL(of: completed) != nil)
    config.keepAudio = true
    let kept = try write(library, "2026-11-07 10.00", .queued, audio: true)
    engine.recover([kept])
    await waitUntil { engine.queue.isEmpty && engine.transcribingID == nil }
    precondition(library.audioURL(of: kept) != nil)
    print(
      "Temporary audio: failures retain audio, successful transcripts delete it only when selected: OK"
    )
  }

  static func testRetention(_ root: URL) throws {
    let transcripts = root.appendingPathComponent("transcripts")
    let audios = root.appendingPathComponent("audios")
    for folder in [transcripts, audios] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func write(_ folder: URL, _ name: String, _ size: Int) throws {
      try Data(repeating: 1, count: size).write(to: folder.appendingPathComponent(name))
    }
    try write(transcripts, "2026-01-01 10.00 Old.txt", 10)
    try write(transcripts, "2026-01-01 10.00.json", 10)
    try write(transcripts, "2026-01-01 10.00 Old.summary.md", 10)
    try write(transcripts, "2026-01-02 10.00.txt", 10)
    try write(transcripts, "2026-01-02 10.00.json", 10)
    try write(transcripts, "2026-01-03 10.00.json", 5)
    try write(transcripts, "2026-01-04 10.00 New.txt", 10)
    try write(audios, "2026-01-01 10.00 Old.m4a", 30)
    try write(audios, "2026-01-02 10.00.m4a", 30)
    try write(audios, "2026-01-04 10.00 New.m4a", 30)
    let original = try Dictionary(
      uniqueKeysWithValues:
        FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        .map { ($0, try Data(contentsOf: $0)) })
    let plan = try RecordingRetention.plan(
      root: root, protected: ["2026-01-02 10.00"], audioBudget: 40)
    precondition(plan.audios.map(\.id) == ["2026-01-01 10.00"] && plan.bytes == 30)
    precondition(plan.summary.hasPrefix("This permanently deletes 1 recording ("))
    precondition(plan.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    let fits = try RecordingRetention.plan(root: root, audioBudget: 90)
    precondition(fits.isEmpty)
    let removed = try RecordingRetention.enforce(
      root: root, protected: ["2026-01-02 10.00"], audioBudget: 40)
    precondition(removed == plan.files)
    let audio = Set(try FileManager.default.contentsOfDirectory(atPath: audios.path))
    precondition(audio == ["2026-01-02 10.00.m4a", "2026-01-04 10.00 New.m4a"])
    for (file, bytes) in original {
      let remaining = try Data(contentsOf: file)
      precondition(remaining == bytes, "Every transcript, record and note stays unchanged")
    }
    let usage = RecordingRetention.usage(root: root)
    precondition(usage.transcriptBytes == 65 && usage.audioBytes == 60)
  }

  @MainActor
  static func testAudioRemoval(_ root: URL) async throws {
    let library = MeetingLibrary(root: root)
    let manager = FileManager.default
    for folder in [library.audios, library.transcripts] {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let statuses: [MeetingStatus] = [
      .complete, .failed, .queued, .recording, .complete, .complete, .complete,
    ]
    var records: [MeetingRecord] = []
    var preserved: [URL: Data] = [:]
    for (index, status) in statuses.enumerated() {
      let id = "2026-01-0\(index + 1) 10.00"
      let record = try write(library, id, status, audio: true)
      records.append(record)
      let file = library.recordURL(for: id)
      preserved[file] = try Data(contentsOf: file)
      if status == .complete && index != 5 {
        let transcript = MeetingFiles.transcript(for: record.fileStem, in: library.transcripts)
        let data = Data("[00:00:00] Speaker 1: Keep this transcript.\n".utf8)
        try data.write(to: transcript)
        preserved[transcript] = data
      }
    }
    let unrelated = library.audios.appendingPathComponent("keep-me.m4a")
    try Data([1, 2, 3]).write(to: unrelated)
    preserved[unrelated] = try Data(contentsOf: unrelated)
    let error = await LibraryReader(root: root).removeCompletedRecordings(protected: [records[4].id]
    )
    precondition(error == nil, "\(error ?? "")")
    for (index, record) in records.enumerated() {
      let exists = library.audioURL(of: record) != nil
      precondition(
        exists == (index != 0 && index != 6),
        "Only completed unprotected audio is removed, including the newest")
    }
    for (file, bytes) in preserved {
      let remaining = try Data(contentsOf: file)
      precondition(remaining == bytes)
    }
    print(
      "Explicit audio removal preserves all transcripts and unfinished/protected recordings: OK")
  }
  @MainActor
  static func testDeleteAll(_ root: URL) throws {
    let manager = FileManager.default
    let library = MeetingLibrary(root: root.appendingPathComponent("meetings"))
    let trash = root.appendingPathComponent("Trash")
    for folder in [library.audios, library.transcripts, trash] {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    library.trash = { file in
      try manager.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
    }
    let complete = try write(library, "2026-01-01 10.00", .complete, audio: true)
    let transcript = MeetingFiles.transcript(for: complete.fileStem, in: library.transcripts)
    try Data("[00:00:00] Speaker 1: Test.\n".utf8).write(to: transcript)
    var pending = try write(library, "2026-01-02 10.00", .queued, audio: true)
    let engine = MeetingEngine(library: library, teams: TeamsMonitor())
    do {
      try engine.deleteAllMeetings()
      preconditionFailure("In-progress meetings must prevent bulk deletion")
    } catch {}
    precondition(library.meetings().count == 2)
    pending.status = .failed
    try library.save(pending)
    engine.recover([pending])
    precondition(engine.unfinished[pending.id] != nil)
    let unrelated = library.transcripts.appendingPathComponent("notes.txt")
    try Data("Keep unrelated files".utf8).write(to: unrelated)
    let expected = Set(
      [complete.id, pending.id].flatMap { library.files(of: $0).map(\.lastPathComponent) })
    let count = try engine.deleteAllMeetings()
    precondition(count == 2 && engine.unfinished.isEmpty && library.meetings().isEmpty)
    let trashed = Set(try manager.contentsOfDirectory(atPath: trash.path))
    precondition(trashed == expected)
    precondition(manager.fileExists(atPath: unrelated.path))
    print(
      "Delete all: protects active work, clears completed and failed meetings, preserves unrelated files: OK"
    )
  }

}

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
    print("Meeting library: records describe meetings; files belong by id: OK")
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
    try testReconstructionArchive(root.appendingPathComponent("reconstruction"))
    print(
      "Retention by meeting id, with extra files, audio, protected meetings and its preview: OK")
  }

  static func date(_ text: String) -> Date { MeetingFiles.date(fromID: text)! }

  @discardableResult
  static func write(
    _ library: MeetingLibrary, _ id: String, _ status: MeetingStatus,
    title: String? = nil, audio: Bool = false, queuedAt: Date? = nil, error: String? = nil
  ) throws -> MeetingRecord {
    var record = MeetingRecord(id: id, title: title, startedAt: date(id), status: status)
    record.queuedAt = queuedAt
    record.error = error
    if audio {
      let file = MeetingFiles.audio(for: record.id, in: library.audios)
      try Data(repeating: 7, count: 64).write(to: file)
      record.audioFile = file.lastPathComponent
      record.durationSeconds = 120
    }
    try library.save(record)
    return record
  }

  static func testScanning(_ library: MeetingLibrary) throws {
    let manager = FileManager.default
    var complete = MeetingRecord(
      id: "20261001T090000Z", title: "Old Sync", startedAt: date("20261001T090000Z"),
      status: .complete)
    complete.transcriptFile = "20261001T090000Z.txt"
    complete.segments = [MeetingSegment(start: 1, end: 2, speaker: "Speaker 1", text: "Hello")]
    try library.save(complete)
    for name in ["20261001T090000Z.txt", "20261001T090000Z.summary.md", "20261001T090000Z-2.txt"] {
      try "[00:00:01] Speaker 1: Hello\n".write(
        to: library.transcripts.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try Data(repeating: 1, count: 16).write(
      to: library.audios.appendingPathComponent("20261002T090000Z.m4a"))
    try manager.createDirectory(
      at: library.captureURL(for: "20261003T090000Z"), withIntermediateDirectories: true)
    try #"{"title":"not ours"}"#.write(
      to: library.transcripts.appendingPathComponent("20261004T090000Z.json"), atomically: true,
      encoding: .utf8)
    try #"{"speakers":[]}"#.write(
      to: library.transcripts.appendingPathComponent("20261001T090000Z.speakers.json"),
      atomically: true, encoding: .utf8)
    let all = library.meetings()
    precondition(all.map(\.id) == ["20261001T090000Z"], "Only records describe meetings")
    precondition(all[0].title == "Old Sync" && all[0].status == .complete)
    do {
      try library.save(MeetingRecord(id: "20261004T090000Z", startedAt: Date(), status: .failed))
      preconditionFailure("A foreign file must not be replaced")
    } catch {}
    try manager.removeItem(at: library.transcripts.appendingPathComponent("20261004T090000Z.json"))
    let encoded = try JSONCoding.encoder().encode(all[0])
    let decoded = try JSONCoding.decoder().decode(MeetingRecord.self, from: encoded)
    precondition(decoded == all[0])
    var future = String(decoding: encoded, as: UTF8.self)
    future = future.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
    precondition(
      (try? JSONCoding.decoder().decode(MeetingRecord.self, from: Data(future.utf8))) == nil)
    precondition(
      Set(library.files(of: "20261001T090000Z").map(\.lastPathComponent))
        == [
          "20261001T090000Z.json", "20261001T090000Z.txt", "20261001T090000Z.summary.md",
          "20261001T090000Z.speakers.json",
        ])
    for name in [
      "20261001T090000Z.json", "20261001T090000Z.txt", "20261001T090000Z.summary.md",
      "20261001T090000Z.speakers.json", "20261001T090000Z-2.txt",
    ] {
      try manager.removeItem(at: library.transcripts.appendingPathComponent(name))
    }
    try manager.removeItem(at: library.audios.appendingPathComponent("20261002T090000Z.m4a"))
    try manager.removeItem(at: library.captureURL(for: "20261003T090000Z"))
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
    let t0 = date("20261105T080000Z")
    try write(library, "20261105T090000Z", .transcribing, title: "First", audio: true, queuedAt: t0)
    try write(
      library, "20261105T100000Z", .queued, title: "Second", audio: true,
      queuedAt: t0.addingTimeInterval(60))
    try write(library, "20261105T110000Z", .recording, title: "Crashed")
    try manager.createDirectory(
      at: library.captureURL(for: "20261105T110000Z"), withIntermediateDirectories: true)
    try write(library, "20261105T120000Z", .saving, audio: true)
    try write(library, "20261105T130000Z", .failed, error: "Saving failed")

    var events: [(LifecycleEvent, String)] = []
    let engine = MeetingEngine(library: library, teams: TeamsMonitor())
    engine.transcriberExecutable = helper
    engine.localSpeakerName = { _ in "Jona" }
    engine.onEvent = { event, record, _ in events.append((event, record.id)) }
    engine.recover(library.recoverable(library.meetings()))
    let recovered = Dictionary(uniqueKeysWithValues: library.meetings().map { ($0.id, $0.status) })
    precondition(recovered["20261105T110000Z"] == .interrupted)
    precondition(recovered["20261105T130000Z"] == .failed)
    precondition(engine.isBusy)
    precondition(engine.protectedIDs.isSuperset(of: ["20261105T100000Z", "20261105T130000Z"]))
    await waitUntil { engine.queue.isEmpty }
    let order = try String(contentsOf: root.appendingPathComponent("order.log"), encoding: .utf8)
    precondition(
      order == "20261105T090000Z.m4a\n20261105T100000Z.m4a\n20261105T120000Z.m4a\n",
      "Unexpected order: \(order)")
    let first = try library.load("20261105T090000Z")
    precondition(first.status == .complete && first.segments.count == 2)
    precondition(first.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
    precondition(first.stage == nil && first.queuedAt == nil)
    let text = try String(contentsOf: library.transcriptURL(of: first)!, encoding: .utf8)
    precondition(text.contains("[00:00:00] Speaker 1: Hello from 20261105T090000Z.m4a"))
    precondition(first.transcriptFile == "20261105T090000Z.txt")
    precondition(
      events.filter { $0.0 == .transcriptReady }.map(\.1)
        == ["20261105T090000Z", "20261105T100000Z", "20261105T120000Z"])
    precondition(events.contains { $0 == (.recordingInterrupted, "20261105T110000Z") })

    // Two failures at once, each retried and discarded on its own.
    try Data().write(to: root.appendingPathComponent("fail"))
    try write(library, "20261105T140000Z", .failed, title: "Alpha", audio: true, error: "Old")
    try write(library, "20261105T150000Z", .failed, title: "Beta", audio: true, error: "Old")
    try engine.retry("20261105T140000Z")
    try engine.retry("20261105T150000Z")
    await waitUntil { engine.queue.isEmpty }
    for id in ["20261105T140000Z", "20261105T150000Z"] {
      let failed = try library.load(id)
      precondition(failed.status == .failed && failed.error == "Fake engine failure")
      precondition(failed.failedAt != nil && library.work(for: failed).canRetry)
    }
    precondition(events.filter { $0.0 == .transcriptionFailed }.count == 2)

    let config = ConfigStore(file: root.appendingPathComponent("config.json"))
    config.load()
    var permissions = PermissionSnapshot(
      microphone: true, systemAudio: true, accessibility: true)
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
    let meetingLink = MeetingLink(meetingID: "20261105T090000Z")
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
    let discardComplete = await refusal(.discard(id: "20261105T090000Z"))
    precondition(discardComplete.contains("Delete the meeting"))
    let retryComplete = await refusal(.retry(id: "20261105T090000Z"))
    precondition(retryComplete.contains("only failed"))
    permissions.accessibility = false
    precondition(commands.startBlockedReason == nil)
    precondition(
      commands.startBlockedReason(automatically: true)?.contains("Accessibility")
        == true)
    permissions.systemAudio = false
    precondition(commands.startBlockedReason?.contains("System Audio") == true)
    let automaticStatus = await commands.status()
    precondition(!automaticStatus.canStartRecording)
    precondition(automaticStatus.missingPermissions == [MeetingPermission.systemAudio.rawValue])
    permissions.microphone = false
    let start = await refusal(.start(title: nil))
    precondition(start.contains("Missing permissions: Microphone, System Audio"))
    precondition(!start.contains("Accessibility"))
    permissions.microphone = true
    permissions.systemAudio = true
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
      "20261105T140000Z", title: .some("Alpha reviewed"), expectedRevision: 0)
    guard
      case .success(let retried) = await commands.perform(
        .retry(id: "20261105T140000Z"), source: .panel)
    else { preconditionFailure("Retry is accepted") }
    precondition(retried.meeting?.status == .queued)
    await waitUntil { engine.queue.isEmpty }
    let alpha = try library.load("20261105T140000Z")
    let beta = try library.load("20261105T150000Z")
    precondition(alpha.status == .complete && beta.status == .failed)
    precondition(alpha.title == "Alpha reviewed" && alpha.revision == 1)
    precondition(alpha.audioFile == "20261105T140000Z.m4a")
    guard case .success = await commands.perform(.delete(id: "20261105T150000Z"), source: .socket)
    else { preconditionFailure("Discard is accepted") }
    precondition((try? library.load("20261105T150000Z")) == nil)
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("20261105T150000Z.json").path))
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("20261105T150000Z.m4a").path))
    do {
      try engine.retry("20261105T130000Z")
      preconditionFailure("Without audio there is nothing to retry")
    } catch {
      precondition(error.localizedDescription.contains("Discard it instead"))
    }
    try write(library, "20261002T090000Z", .untranscribed, title: "Orphan", audio: true)
    try write(
      library, "20261003T090000Z", .interrupted,
      error: "The recording was interrupted before its audio was saved.")
    try manager.createDirectory(
      at: library.captureURL(for: "20261003T090000Z"), withIntermediateDirectories: true)
    let single = await commands.perform(.retry(id: nil), source: .url)
    if case .success = single { preconditionFailure("Several meetings still need attention") }
    try await engine.discard("20261105T130000Z")
    try await engine.discard("20261105T110000Z")
    try await engine.discard("20261003T090000Z")
    precondition(library.needingAttention().map(\.id) == ["20261002T090000Z"])
    guard case .success(let only) = await commands.perform(.retry(id: nil), source: .url)
    else { preconditionFailure("The only meeting that needs attention can be retried") }
    precondition(only.meeting?.id == "20261002T090000Z")
    await waitUntil { engine.queue.isEmpty }
    let orphan = try library.load("20261002T090000Z")
    precondition(orphan.status == .complete && orphan.title == "Orphan")
    precondition(
      library.transcriptURL(of: orphan)?.lastPathComponent == "20261002T090000Z.txt")

    guard case .success = await commands.perform(.delete(id: "20261105T090000Z"), source: .library)
    else { preconditionFailure("Delete is accepted") }
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("20261105T090000Z.txt").path))
    precondition(events.contains { $0 == (.meetingDeleted, "20261105T090000Z") })
    guard
      case .success = await commands.perform(
        .renameSpeakers(id: "Second", names: ["1": "Ada"]), source: .socket)
    else { preconditionFailure("Rename is accepted") }
    let second = try library.load("20261105T100000Z")
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
    try write(library, "20261105T160000Z", .failed, title: "Gamma", audio: true, error: "Old")
    try engine.retry("20261105T160000Z")
    await waitUntil { engine.queue.first?.stage == "Transcribing part 1 of 2" }
    try write(library, "20261105T163000Z", .failed, title: "Queued deletion", audio: true)
    try engine.retry("20261105T163000Z")
    precondition(engine.queue.contains { $0.id == "20261105T163000Z" && $0.status == .queued })
    guard case .success = await commands.perform(.delete(id: "20261105T163000Z"), source: .socket)
    else { preconditionFailure("Deleting queued work is accepted") }
    precondition((try? library.load("20261105T163000Z")) == nil)
    precondition(!engine.queue.contains { $0.id == "20261105T163000Z" })
    let discardStarted = Date()
    guard case .success = await commands.perform(.delete(id: "20261105T160000Z"), source: .socket)
    else { preconditionFailure("Discarding a transcribing meeting is accepted") }
    precondition(engine.queue.isEmpty)
    await waitUntil { engine.transcribingID == nil }
    precondition(Date().timeIntervalSince(discardStarted) < 10, "The engine stops right away")
    precondition((try? library.load("20261105T160000Z")) == nil)
    precondition(
      !manager.fileExists(
        atPath: library.transcripts.appendingPathComponent("20261105T160000Z.txt").path))
    precondition(
      manager.fileExists(atPath: trash.appendingPathComponent("20261105T160000Z.m4a").path))
    precondition(events.contains { $0 == (.meetingDiscarded, "20261105T160000Z") })
    precondition(!events.contains { $0 == (.transcriptionFailed, "20261105T160000Z") })
    try manager.removeItem(at: root.appendingPathComponent("slow"))

    let status = await commands.status()
    precondition(status.running && status.queue.isEmpty && status.recording == nil)
    precondition(status.lastTranscriptId == "20261105T140000Z")
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
        library, "20261105T190\(index)00Z", state, title: "Discard failure", audio: true)
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
      library, "20261105T180000Z", .failed, title: "Save failure", audio: true)
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
        atPath: MeetingFiles.transcript(for: record.id, in: library.transcripts).path))
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
    let failed = try write(library, "20261107T090000Z", .queued, audio: true)
    let audio = library.audioURL(of: failed)!
    func capture(_ id: String) throws -> URL {
      let capture = library.captureURL(for: id)
      try manager.createDirectory(at: capture, withIntermediateDirectories: true)
      try Data("tracks".utf8).write(to: capture.appendingPathComponent("microphone.aac"))
      return capture
    }
    let failedCapture = try capture(failed.id)
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
    let archive = ReconstructionArchive.url(for: failed.id)
    precondition(
      !manager.fileExists(atPath: failedCapture.path) && !manager.fileExists(atPath: archive.path),
      "Without kept audio the capture tracks are deleted and nothing is archived")
    config.keepAudio = true
    let kept = try write(library, "20261107T100000Z", .queued, audio: true)
    let keptCapture = try capture(kept.id)
    engine.recover([kept])
    await waitUntil { engine.queue.isEmpty && engine.transcribingID == nil }
    precondition(library.audioURL(of: kept) != nil)
    let archived = ReconstructionArchive.url(for: kept.id)
    let details = try JSONDecoder().decode(
      ReconstructionArchive.Transcription.self,
      from: Data(contentsOf: archived.appendingPathComponent("transcription.json")))
    precondition(
      !manager.fileExists(atPath: keptCapture.path)
        && manager.fileExists(
          atPath: archived.appendingPathComponent("capture/microphone.aac").path)
        && details.helper?.segments.count == 2,
      "With kept audio the capture tracks move to the archive with the helper's result")
    precondition(library.files(of: kept.id).contains(archived))
    let corrected = try library.load(kept.id)
    try library.editTranscript(
      kept.id, changes: [MeetingTextChange(segmentID: "s1", text: "Corrected.")],
      expectedRevision: corrected.revision)
    precondition(
      !manager.fileExists(atPath: archived.appendingPathComponent("transcription.json").path)
        && manager.fileExists(
          atPath: archived.appendingPathComponent("capture/microphone.aac").path),
      "A correction leaves no uncorrected transcription in the archive")
    config.keepAudio = false
    engine.enforceRetention()
    precondition(
      !manager.fileExists(atPath: archived.path), "Turning off kept audio removes the archive")
    print(
      "Temporary audio: failures retain audio, successful transcripts delete it only when selected: OK"
    )
  }

  static func testReconstructionArchive(_ root: URL) throws {
    let manager = FileManager.default
    let result = TranscriptSegments(
      mode: .separateTracks, duration: 2,
      segments: [.init(start: 0, end: 2, source: .teams, speaker: "S1", text: "Hi")],
      voiceEmbeddings: [.init(speaker: "S1", start: 0, end: 2, values: [1, 0])],
      engine: "fixture")
    let ids = ["20261101T090000Z", "20261102T090000Z", "20261103T090000Z", "20261104T090000Z"]
    for (id, size) in zip(ids, [60, 50, 70, 40]) {
      let capture = root.appendingPathComponent("capture-\(id)")
      try manager.createDirectory(at: capture, withIntermediateDirectories: true)
      try Data(repeating: 1, count: size).write(to: capture.appendingPathComponent("system.aac"))
      try ReconstructionArchive.keepTrace(Data("{}\n".utf8), id: id, in: root)
      try ReconstructionArchive.keep(
        capture: capture, id: id, result: result,
        naming: [.init(name: "Anna", reason: .teamsReading, anchor: true)], app: "fixture",
        in: root)
    }
    let first = ReconstructionArchive.url(for: ids[0], in: root)
    let json = try String(
      contentsOf: first.appendingPathComponent("transcription.json"), encoding: .utf8)
    precondition(
      !json.contains("voiceEmbeddings") && json.contains("teams-reading")
        && manager.fileExists(atPath: first.appendingPathComponent("teams-trace.jsonl").path),
      "The archive keeps the trace and naming evidence but no voice embeddings")
    func archived() -> [String] {
      ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).filter {
        $0.hasPrefix("2026")
      }.sorted()
    }
    precondition(
      ReconstructionArchive.enforce(keepAudio: true, budget: 2_000_000, in: root) == []
        && archived() == ids, "Archives within the budget stay")
    let overhead = Int64(
      (try Data(contentsOf: first.appendingPathComponent("transcription.json"))).count + 3)
    precondition(
      ReconstructionArchive.enforce(
        keepAudio: true, protected: [ids[0]], budget: 110 + 2 * overhead, in: root)
        == [ids[1], ids[2]] && archived() == [ids[0], ids[3]],
      "The oldest archives go first, sparing unfinished and failed meetings")
    precondition(
      ReconstructionArchive.enforce(keepAudio: true, budget: 1, in: root) == [ids[0]]
        && archived() == [ids[3]], "The newest archive stays even above the budget")
    try ReconstructionArchive.remove([ids[3]], in: root)
    precondition(archived().isEmpty, "Removing a meeting's audio removes its archive")
    for id in ids.prefix(3) { try ReconstructionArchive.keepTrace(Data(), id: id, in: root) }
    precondition(
      ReconstructionArchive.enforce(
        keepAudio: true, protected: [ids[1]], exists: { $0 == ids[2] }, in: root)
        == [ids[0]] && archived() == [ids[1], ids[2]],
      "An archive whose meeting is gone is removed, unless the meeting is still unfinished")
    precondition(
      ReconstructionArchive.enforce(keepAudio: false, in: root) == [ids[1], ids[2]]
        && archived().isEmpty,
      "Without kept audio nothing stays")
    func capture(_ name: String) throws -> URL {
      let folder = root.appendingPathComponent(name)
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data([1]).write(to: folder.appendingPathComponent("microphone.aac"))
      return folder
    }
    let id = ids[0]
    let target = ReconstructionArchive.url(for: id, in: root)
    try ReconstructionArchive.keep(
      capture: try capture("first"), id: id, result: result, naming: nil, in: root)
    let corrected = try capture("corrected")
    try ReconstructionArchive.keep(
      capture: corrected, id: id, result: result, naming: nil, in: root
    ) { .captureOnly }
    precondition(
      manager.fileExists(atPath: target.appendingPathComponent("capture/microphone.aac").path)
        && !manager.fileExists(atPath: target.appendingPathComponent("transcription.json").path)
        && !manager.fileExists(atPath: corrected.path),
      "A transcript corrected before archiving leaves only its capture tracks")
    try ReconstructionArchive.remove([id], in: root)
    let deleted = try capture("deleted")
    try ReconstructionArchive.keep(
      capture: deleted, id: id, result: result, naming: nil, in: root
    ) { .nothing }
    precondition(
      !manager.fileExists(atPath: target.path) && !manager.fileExists(atPath: deleted.path),
      "A meeting deleted or without audio before archiving leaves nothing")
    ReconstructionArchive.setKeepsAudio(false)
    try ReconstructionArchive.keep(
      capture: try capture("off"), id: id, result: result, naming: nil, in: root)
    try ReconstructionArchive.keepTrace(Data("{}\n".utf8), id: id, in: root)
    precondition(
      !manager.fileExists(atPath: target.path),
      "Nothing is archived after kept audio was turned off")
    ReconstructionArchive.setKeepsAudio(true)
    print("Reconstruction archive: budget, oldest first, newest kept, no embeddings: OK")
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
    try write(transcripts, "20260101T100000Z.txt", 10)
    try write(transcripts, "20260101T100000Z.json", 10)
    try write(transcripts, "20260101T100000Z.summary.md", 10)
    try write(transcripts, "20260102T100000Z.txt", 10)
    try write(transcripts, "20260102T100000Z.json", 10)
    try write(transcripts, "20260103T100000Z.json", 5)
    try write(transcripts, "20260104T100000Z.txt", 10)
    try write(audios, "20260101T100000Z.m4a", 30)
    try write(audios, "20260102T100000Z.m4a", 30)
    try write(audios, "20260104T100000Z.m4a", 30)
    let original = try Dictionary(
      uniqueKeysWithValues:
        FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        .map { ($0, try Data(contentsOf: $0)) })
    let plan = try RecordingRetention.plan(
      root: root, protected: ["20260102T100000Z"], audioBudget: 40)
    precondition(plan.audios.map(\.id) == ["20260101T100000Z"] && plan.bytes == 30)
    precondition(plan.summary.hasPrefix("This permanently deletes 1 recording ("))
    precondition(plan.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    let fits = try RecordingRetention.plan(root: root, audioBudget: 90)
    precondition(fits.isEmpty)
    for id in ["20260101T100000Z", "20260102T100000Z"] {
      try ReconstructionArchive.keepTrace(Data("{}\n".utf8), id: id)
    }
    let removed = try RecordingRetention.enforce(
      root: root, protected: ["20260102T100000Z"], audioBudget: 40)
    precondition(removed == plan.files)
    precondition(
      !FileManager.default.fileExists(
        atPath: ReconstructionArchive.url(for: "20260101T100000Z").path)
        && FileManager.default.fileExists(
          atPath: ReconstructionArchive.url(for: "20260102T100000Z").path),
      "Retention removes the archive of every recording whose audio it deletes")
    try ReconstructionArchive.remove(["20260102T100000Z"])
    let audio = Set(try FileManager.default.contentsOfDirectory(atPath: audios.path))
    precondition(audio == ["20260102T100000Z.m4a", "20260104T100000Z.m4a"])
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
      let id = "2026010\(index + 1)T100000Z"
      let record = try write(library, id, status, audio: true)
      records.append(record)
      let file = library.recordURL(for: id)
      preserved[file] = try Data(contentsOf: file)
      if status == .complete && index != 5 {
        let transcript = MeetingFiles.transcript(for: record.id, in: library.transcripts)
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
    let complete = try write(library, "20260101T100000Z", .complete, audio: true)
    let transcript = MeetingFiles.transcript(for: complete.id, in: library.transcripts)
    try Data("[00:00:00] Speaker 1: Test.\n".utf8).write(to: transcript)
    var pending = try write(library, "20260102T100000Z", .queued, audio: true)
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

import AVFoundation
import CoreAudio
import Foundation

@main
struct Smoke {
  @MainActor
  static func main() async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--mcp-fixture" {
      try AgentFixture.run(root: URL(fileURLWithPath: CommandLine.arguments[2]))
      return
    }
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--edit-fixture-writer" {
      try TranscriptEditsSmoke.writeFixture(
        root: URL(fileURLWithPath: CommandLine.arguments[2]), text: CommandLine.arguments[3])
      return
    }

    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == captureUntilKilledFlag {
      try await captureUntilKilled(
        directory: URL(fileURLWithPath: CommandLine.arguments[2]),
        ready: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
    precondition(SystemAudioAuthorization.isReadable)
    print("System audio permission is read from macOS: OK")
    SoundSmoke.run()
    try SpeakerIdentitySmoke.run()
    try AgentSmoke.run()
    try TranscriptEditsSmoke.run()
    try MeetingTitlesSmoke.run()
    try MigrationSmoke.run()
    try AgentEditingSmoke.run()
    TranscriptScrollSmoke.run()
    try testPausedMeetingLinks()
    let updateGate = UpdateInstallationGate()
    var installs = 0
    precondition(updateGate.postpone(whileBusy: true) { installs += 1 })
    updateGate.resumeIfIdle(false)
    precondition(installs == 0 && !updateGate.installationStarted)
    updateGate.resumeIfIdle(true)
    updateGate.resumeIfIdle(true)
    precondition(installs == 1 && updateGate.installationStarted)
    updateGate.reset()
    precondition(!updateGate.installationStarted)
    precondition(updateGate.postpone(whileBusy: true) { installs += 1 })
    updateGate.reset()
    updateGate.resumeIfIdle(true)
    precondition(installs == 1)
    precondition(!updateGate.postpone(whileBusy: false) { installs += 1 })
    precondition(updateGate.installationStarted && installs == 1)
    updateGate.reset()
    updateGate.installWhenIdle { installs += 1 }
    precondition(installs == 1 && !updateGate.installationStarted)
    updateGate.resumeIfIdle(false)
    precondition(installs == 1 && !updateGate.installationStarted)
    updateGate.resumeIfIdle(true)
    updateGate.resumeIfIdle(true)
    precondition(installs == 2 && updateGate.installationStarted)
    updateGate.reset()
    updateGate.installWhenIdle { installs += 1 }
    updateGate.reset()
    updateGate.resumeIfIdle(true)
    precondition(installs == 2 && !updateGate.installationStarted)
    print("Update installation waits for work, resumes once, and clears failed attempts: OK")
    SpeechPlanSmoke.run()
    for microphone in [false, true] {
      for systemAudio in [false, true] {
        for accessibility in [false, true] {
          let permissions = PermissionSnapshot(
            microphone: microphone, systemAudio: systemAudio,
            accessibility: accessibility)
          precondition(
            permissions.recordingGranted == (microphone && systemAudio && accessibility))
          precondition(permissions.missing.contains(.microphone) == !microphone)
          precondition(permissions.missing.contains(.systemAudio) == !systemAudio)
          precondition(permissions.missing.contains(.accessibility) == !accessibility)
          precondition(
            permissions.missingForRecording().isEmpty == (microphone && systemAudio))
          precondition(
            permissions.missingForRecording(automatically: true).isEmpty
              == permissions.recordingGranted)
        }
      }
    }
    precondition(
      PermissionSnapshot(microphone: false, systemAudio: false, accessibility: false)
        .missing
        == [.microphone, .systemAudio, .accessibility])
    var setupSteps: [String] = []
    let permissionModel = AppModel()
    for permission in MeetingPermission.setupOrder {
      precondition(permissionModel.statusText(for: permission) == "Not allowed")
    }
    permissionModel.permissions = PermissionSnapshot(
      microphone: true, systemAudio: true, accessibility: true)
    precondition(!permissionModel.allPermissionsGranted)
    permissionModel.folderAccess = .denied("Access denied")
    precondition(!permissionModel.allPermissionsGranted)
    permissionModel.folderAccess = .granted
    precondition(permissionModel.allPermissionsGranted)
    for permission in MeetingPermission.setupOrder {
      precondition(permissionModel.statusText(for: permission) == "Allowed")
    }
    permissionModel.systemAudioBlocked = true
    precondition(!permissionModel.allPermissionsGranted)
    precondition(permissionModel.statusText(for: .systemAudio) == "Not allowed")
    precondition(MeetingPermission.documents.settingsURL.query == "Privacy_FilesAndFolders")
    try await PermissionAccess.requestInOrder(
      microphone: {
        setupSteps.append("microphone")
        return true
      },
      systemAudio: {
        setupSteps.append("systemAudio.request")
        await Task.yield()
        setupSteps.append("systemAudio.finished")
      },
      accessibility: { setupSteps.append("accessibility") })
    precondition(
      setupSteps == ["microphone", "systemAudio.request", "systemAudio.finished", "accessibility"])
    setupSteps.removeAll()
    do {
      try await PermissionAccess.requestInOrder(
        microphone: {
          setupSteps.append("microphone")
          return false
        },
        systemAudio: { setupSteps.append("systemAudio") },
        accessibility: { setupSteps.append("accessibility") })
      preconditionFailure("Denied microphone access must stop setup")
    } catch {
      precondition(PermissionAccess.deniedPermission(for: error) == .microphone)
    }
    precondition(setupSteps == ["microphone"])
    setupSteps.removeAll()
    do {
      try await PermissionAccess.requestInOrder(
        microphone: {
          setupSteps.append("microphone")
          return true
        },
        systemAudio: {
          setupSteps.append("systemAudio")
          throw PermissionRequired(permission: .systemAudio)
        },
        accessibility: { setupSteps.append("accessibility") })
      preconditionFailure("A failed system audio request must stop before Accessibility")
    } catch {
      precondition(PermissionAccess.deniedPermission(for: error) == .systemAudio)
    }
    precondition(setupSteps == ["microphone", "systemAudio"])
    print(
      "Setup requests microphone, then system audio, then Accessibility; failures stop the sequence: OK"
    )
    precondition(
      PermissionAccess.deniedPermission(for: PermissionRequired(permission: .microphone))
        == .microphone)
    let denied = CoreAudioFailure(
      operation: "Start Teams audio", status: kAudioDevicePermissionsError)
    precondition(PermissionAccess.deniedPermission(for: denied) == .systemAudio)
    let deviceFailure = CoreAudioFailure(
      operation: "Start Teams audio", status: kAudioHardwareBadDeviceError)
    precondition(PermissionAccess.deniedPermission(for: deviceFailure) == nil)
    precondition(PermissionAccess.deniedPermission(for: MeetingError("Disk full")) == nil)
    var retry = CaptureRetryPolicy()
    precondition(retry.allowsAutomaticStart)
    retry.failed(with: denied)
    precondition(!retry.allowsAutomaticStart)
    retry.failed(with: deviceFailure)
    precondition(!retry.allowsAutomaticStart)
    retry.retryManually()
    precondition(retry.allowsAutomaticStart)
    retry.failed(with: deviceFailure)
    precondition(retry.allowsAutomaticStart)
    print("Permission prerequisites and explicit system audio denial recovery: OK")
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
      "meeting-tests-\(UUID().uuidString)")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let audios = root.appendingPathComponent("audios")
    let transcripts = root.appendingPathComponent("transcripts")
    try manager.createDirectory(at: audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: transcripts, withIntermediateDirectories: true)
    for stem in ["19700101T000000Z", "19700101T000001Z", "19700101T000002Z"] {
      try Data(repeating: 1, count: 20).write(to: audios.appendingPathComponent(stem + ".m4a"))
      try Data(repeating: 1, count: 10).write(to: transcripts.appendingPathComponent(stem + ".txt"))
    }
    let unrelated = audios.appendingPathComponent("keep-me.m4a")
    try Data(repeating: 1, count: 200).write(to: unrelated)
    try testNaming(root: root.appendingPathComponent("naming"))
    try await MeetingSmoke.run(root: root.appendingPathComponent("meetings"))
    print("Local-time filenames, meeting titles, and mixed-format retention order: OK")
    func exists(_ folder: URL, _ name: String) -> Bool {
      manager.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
    try RecordingRetention.enforce(
      root: root, protected: ["19700101T000000Z"], audioBudget: 40)
    precondition(exists(audios, "19700101T000000Z.m4a"))
    precondition(!exists(audios, "19700101T000001Z.m4a"))
    precondition(exists(audios, "19700101T000002Z.m4a"))
    for stem in ["19700101T000000Z", "19700101T000001Z", "19700101T000002Z"] {
      precondition(exists(transcripts, stem + ".txt"))
    }
    try RecordingRetention.enforce(root: root, audioBudget: 10)
    precondition(!exists(audios, "19700101T000000Z.m4a"))
    precondition(exists(audios, "19700101T000002Z.m4a"))
    precondition(exists(transcripts, "19700101T000000Z.txt"))
    precondition(exists(transcripts, "19700101T000001Z.txt"))
    precondition(exists(transcripts, "19700101T000002Z.txt"))
    precondition(manager.fileExists(atPath: unrelated.path))
    precondition(TeamsMuteState.muted.microphoneMuted)
    precondition(!TeamsMuteState.unmuted.microphoneMuted)
    for reason: TeamsMuteState.Reason in [
      .accessibilityPermission, .teamsClosed, .noMeeting, .noControl, .ambiguous,
      .accessibilityError,
    ] {
      precondition(!TeamsMuteState.unavailable(reason).microphoneMuted)
    }
    try await testAudioCapture(root: root.appendingPathComponent("audio-capture"))
    try await testCaptureRecovery(root: root.appendingPathComponent("capture-recovery"))
    testTeamsDetection()
    print("English and German Teams meeting, mute, and title detection: OK")
    precondition(TeamsMuteState.muted.meetingPresence == .inMeeting)
    precondition(TeamsMuteState.unavailable(.noControl).meetingPresence == .inMeeting)
    precondition(TeamsMuteState.unavailable(.teamsClosed).meetingPresence == .noMeeting)
    precondition(TeamsMuteState.unavailable(.accessibilityError).meetingPresence == .unknown)
    testAutoRecordPolicy()
    print("Teams auto-record: starts, stops after grace, respects manual control: OK")
    try testAutomation(root: root.appendingPathComponent("automation"))
    testMeetingLinks()
    print("HTTPS and native meeting links: origins, encoding, times and segments: OK")
    try testStatus(root: root.appendingPathComponent("status"))
    try await testNonBlockingStartup(root: root.appendingPathComponent("startup"))

    let capture = root.appendingPathComponent("capture")
    try manager.createDirectory(at: capture, withIntermediateDirectories: true)
    try writeTrack(at: capture.appendingPathComponent("system.aac"), muted: false)
    try writeTrack(at: capture.appendingPathComponent("microphone.aac"), muted: true)
    try JSONEncoder().encode(CaptureManifest(systemStart: 100, microphoneStart: 100.5)).write(
      to: capture.appendingPathComponent("capture.json"))
    let mixed = root.appendingPathComponent("mixed.m4a")
    try NativeRecorder.mix(directory: capture, destination: mixed)
    let file = try AVAudioFile(forReading: mixed)
    precondition(abs(Double(file.length) / file.processingFormat.sampleRate - 1.5) < 0.1)
    let mixedDuration = try NativeTranscriber.duration(of: mixed)
    precondition(abs(mixedDuration - 1.5) < 0.1)
    precondition(
      NativeTranscriber.failure(status: ["stage": "Failed", "noSpeech": "true"], code: 1)
        is NoSpeechDetected)
    precondition(
      !(NativeTranscriber.failure(status: ["stage": "Failed", "error": "Disk full"], code: 1)
        is NoSpeechDetected))
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = buffer.floatChannelData![0]
    let earlyEnergy = (5_000..<30_000).reduce(Float(0)) { $0 + abs(samples[$1]) }
    let tailEnergy = (55_000..<65_000).reduce(Float(0)) { $0 + abs(samples[$1]) }
    precondition(earlyEnergy > 100 && tailEnergy < 1)
    do {
      try NativeRecorder.mix(directory: capture, destination: mixed)
      preconditionFailure("Must refuse to overwrite audio")
    } catch {}
    let microphoneOnly = root.appendingPathComponent("microphone-only")
    try manager.createDirectory(at: microphoneOnly, withIntermediateDirectories: true)
    try writeTrack(at: microphoneOnly.appendingPathComponent("microphone.aac"), muted: false)
    try JSONEncoder().encode(CaptureManifest(microphoneStart: 100)).write(
      to: microphoneOnly.appendingPathComponent("capture.json"))
    let microphoneOutput = root.appendingPathComponent("microphone-only.m4a")
    try NativeRecorder.mix(directory: microphoneOnly, destination: microphoneOutput)
    let microphoneFile = try AVAudioFile(forReading: microphoneOutput)
    precondition(
      abs(Double(microphoneFile.length) / microphoneFile.processingFormat.sampleRate - 1) < 0.1)
    let microphoneBuffer = AVAudioPCMBuffer(
      pcmFormat: microphoneFile.processingFormat,
      frameCapacity: AVAudioFrameCount(microphoneFile.length))!
    try microphoneFile.read(into: microphoneBuffer)
    let microphoneEnergy = (5_000..<30_000).reduce(Float(0)) {
      $0 + abs(microphoneBuffer.floatChannelData![0][$1])
    }
    precondition(microphoneEnergy > 100)
    print("Optional Teams capture, missing mute detection, and microphone-only mixing: OK")
    print("Native AAC conversion, mute, mixing, timestamps, retention, recovery, and filenames: OK")
    if [4, 5].contains(CommandLine.arguments.count) && CommandLine.arguments[1] == "--transcribe" {
      let result = try await NativeTranscriber().transcribe(
        file: URL(fileURLWithPath: CommandLine.arguments[2]),
        executable: URL(fileURLWithPath: CommandLine.arguments[3]))
      precondition(result.mode == .mixed && !result.segments.isEmpty)
      if CommandLine.arguments.count == 5 {
        let expected = Int(CommandLine.arguments[4])!
        let labels = Set(result.segments.map(\.speaker))
        precondition(labels.count == expected, "Unexpected speaker count: \(labels)")
        print("Expected speaker count \(expected): OK")
      }
      print("Native transcription with timestamps and speaker labels: OK")
    }
  }

  private static func testNaming(root: URL) throws {
    let manager = FileManager.default
    let audios = root.appendingPathComponent("audios")
    let transcripts = root.appendingPathComponent("transcripts")
    try manager.createDirectory(at: audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: transcripts, withIntermediateDirectories: true)
    let epoch = Date(timeIntervalSince1970: 0.75)
    func id() -> String {
      MeetingFiles.id(startingAt: epoch, in: audios, transcriptDirectory: transcripts)
    }
    precondition(id() == "19700101T000000Z")
    try Data().write(to: transcripts.appendingPathComponent("19700101T000000Z.txt"))
    precondition(id() == "19700101T000000Z-2")
    try manager.createDirectory(
      at: audios.appendingPathComponent(".19700101T000000Z-2.recording"),
      withIntermediateDirectories: true)
    precondition(id() == "19700101T000000Z-3")

    let start = Date(timeIntervalSince1970: 0)
    precondition(MeetingFiles.date(fromID: "19700101T000000Z") == start)
    precondition(MeetingFiles.date(fromID: "19700101T000000Z-2") == start)
    precondition(MeetingFiles.date(fromID: "19700101T000000Z-0") == nil)
    precondition(MeetingFiles.date(fromID: "19700101T000000Z Weekly") == nil)
    precondition(MeetingFiles.date(fromID: "1970-01-01 00.00") == nil)
    precondition(MeetingFiles.date(fromID: "keep-me") == nil)

    precondition(
      MeetingFiles.displayTitle("  Produkt-Sync:\n Export-Launch ") == "Produkt-Sync: Export-Launch"
    )
    precondition(MeetingFiles.displayTitle(" \n ") == nil)
    precondition(
      MeetingFiles.id(fromFileName: "19700101T000000Z-2.summary.md") == "19700101T000000Z-2")
    precondition(MeetingFiles.id(fromFileName: "19700101T000000Z.json") == "19700101T000000Z")
    precondition(MeetingFiles.id(fromFileName: "19700101T000000Z.m4a") == "19700101T000000Z")
    precondition(MeetingFiles.id(fromFileName: "19700101T000000Z") == nil)
    precondition(MeetingFiles.id(fromFileName: "19700101T000000Z Weekly Sync.txt") == nil)
    precondition(MeetingFiles.id(fromFileName: ".19700101T000000Z.recording") == nil)
    precondition(MeetingFiles.id(fromFileName: "1970-01-01 00.00.json") == nil)
    precondition(MeetingFiles.id(fromFileName: "keep-me.m4a") == nil)

    let calendar = TeamsWindowSnapshot(title: "Calendar | Microsoft Teams", buttons: [["Chat"]])
    let meeting = TeamsWindowSnapshot(
      title: "Weekly Sync | Microsoft Teams", buttons: [["Leave"], ["Mute mic"]])
    precondition(TeamsMuteClassifier.meetingTitle([calendar, meeting]) == "Weekly Sync")
    precondition(TeamsMuteClassifier.meetingTitle([calendar]) == nil)
    precondition(
      TeamsMuteClassifier.meetingTitle([
        TeamsWindowSnapshot(title: "Calendar | Microsoft Teams", buttons: [["Leave"]])
      ]) == nil)

    let retention = root.appendingPathComponent("retention")
    let retainedAudios = retention.appendingPathComponent("audios")
    try manager.createDirectory(at: retainedAudios, withIntermediateDirectories: true)
    for name in ["20260928T073121Z", "20260929T144200Z", "20260930T090000Z"] {
      try Data(repeating: 1, count: 20).write(
        to: retainedAudios.appendingPathComponent(name + ".m4a"))
    }
    try RecordingRetention.enforce(root: retention, audioBudget: 45)
    precondition(
      !manager.fileExists(
        atPath: retainedAudios.appendingPathComponent("20260928T073121Z.m4a").path))
    precondition(
      manager.fileExists(
        atPath: retainedAudios.appendingPathComponent("20260929T144200Z.m4a").path))
    precondition(
      manager.fileExists(
        atPath: retainedAudios.appendingPathComponent("20260930T090000Z.m4a").path))
  }

  private static func testTeamsDetection() {
    let titleCases: [(String, String?)] = [
      ("Mittagspause | Microsoft Teams", "Mittagspause"),
      ("Mittagspause - Microsoft Teams", "Mittagspause"),
      ("Mittagspause | Example GmbH | user@example.com | Microsoft Teams", "Mittagspause"),
      ("Mittagspause | Example GmbH | user@example.com - Microsoft Teams", "Mittagspause"),
      ("Mittagspause | Example GmbH | user@example.com", "Mittagspause"),
      (
        "  Planning | Q4 | Example GmbH | user+work@example.co.uk | Microsoft Teams  ",
        "Planning | Q4"
      ),
      ("Planning | Q4 | Microsoft Teams", "Planning | Q4"),
      ("Planning | Q4 | Notes", "Planning | Q4 | Notes"),
      ("Planning | user@example.com", "Planning | user@example.com"),
      ("Planning | Example GmbH | user@", "Planning | Example GmbH | user@"),
      ("Planning |  | user@example.com", "Planning |  | user@example.com"),
      ("Calendar | Example GmbH | user@example.com | Microsoft Teams", nil),
    ]
    for (leave, unmute, mute) in [
      ("Leave", "Unmute mic", "Mute mic"),
      ("Verlassen", "Mikrofon wieder aktivieren", "Mikrofon stummschalten"),
    ] {
      for (title, expected) in titleCases {
        let meeting = TeamsWindowSnapshot(title: title, buttons: [[leave], [mute]])
        precondition(TeamsMuteClassifier.meetingTitle([meeting]) == expected)
        precondition(TeamsMuteClassifier.classify([meeting]) == .unmuted)
      }
      let accountPrejoin = TeamsWindowSnapshot(
        title: "Meeting join | Mittagspause | Example GmbH | user@example.com | Microsoft Teams",
        buttons: [[mute], ["Join now"]])
      precondition(TeamsMuteClassifier.meetingTitle([accountPrejoin]) == nil)
      precondition(TeamsMuteClassifier.classify([accountPrejoin]) == .unavailable(.noMeeting))
      let calendar = TeamsWindowSnapshot(title: "Calendar | Microsoft Teams", buttons: [["Chat"]])
      for (action, expected) in [(unmute, TeamsMuteState.muted), (mute, TeamsMuteState.unmuted)] {
        let meeting = TeamsWindowSnapshot(
          title: "Mittagspause | Microsoft Teams", buttons: [[leave], [action]])
        let state = TeamsMuteClassifier.classify([calendar, meeting])
        precondition(state == expected)
        precondition(state.meetingPresence == .inMeeting)
        precondition(TeamsMuteClassifier.meetingTitle([calendar, meeting]) == "Mittagspause")
        for labels in [["\(action.uppercased()) (⇧ ⌘ M)"], [action, "\(action) (⇧ ⌘ M)"]] {
          precondition(
            TeamsMuteClassifier.classify([
              TeamsWindowSnapshot(buttons: [[leave.uppercased()], labels])
            ]) == expected)
        }
        let compactView = TeamsWindowSnapshot(
          title: "Mittagspause | Microsoft Teams", buttons: [[leave]])
        precondition(TeamsMuteClassifier.classify([meeting, meeting]) == expected)
        precondition(TeamsMuteClassifier.classify([compactView, meeting]) == expected)
        precondition(
          TeamsMuteClassifier.meetingTitle([compactView, meeting]) == "Mittagspause")
        let otherMeeting = TeamsWindowSnapshot(
          title: "Kundencall | Microsoft Teams",
          buttons: [[leave], [action == mute ? unmute : mute]])
        precondition(
          TeamsMuteClassifier.classify([meeting, otherMeeting]) == .unavailable(.ambiguous))
        precondition(TeamsMuteClassifier.meetingTitle([meeting, otherMeeting]) == nil)

        let prejoin = TeamsWindowSnapshot(
          title: "Mittagspause | Microsoft Teams", buttons: [[action]])
        precondition(TeamsMuteClassifier.classify([prejoin]) == .unavailable(.noMeeting))
        precondition(TeamsMuteClassifier.meetingTitle([prejoin]) == nil)
      }
      let missingMicrophone = TeamsWindowSnapshot(buttons: [[leave]])
      let missingState = TeamsMuteClassifier.classify([missingMicrophone])
      precondition(missingState == .unavailable(.noControl))
      precondition(missingState.meetingPresence == .inMeeting)
      precondition(!missingState.microphoneMuted)
      precondition(
        TeamsMuteClassifier.classify([
          TeamsWindowSnapshot(buttons: [[leave], [unmute, mute]])
        ]) == .unavailable(.ambiguous))
      precondition(
        TeamsMuteClassifier.classify([
          TeamsWindowSnapshot(buttons: [[leave], [unmute], [mute]])
        ]) == .unavailable(.ambiguous))
    }
  }

  private static func testAutoRecordPolicy() {
    let start = Date(timeIntervalSince1970: 0)
    let grace = TeamsAutoRecordPolicy.leaveGracePeriod
    var manual = TeamsAutoRecordPolicy()
    _ = manual.observe(.noMeeting, at: start, isRecording: false, canStart: true)
    _ = manual.observe(.noMeeting, at: start + grace, isRecording: false, canStart: true)
    manual.recordingStarted(automatically: false)
    manual.recordingEnded()
    precondition(
      !manual.waitingForMeetingEnd, "A manual recording outside Teams must not pause auto-record")
    precondition(
      manual.observe(.inMeeting, at: start + 1, isRecording: false, canStart: true) == .start)

    var quickLeave = TeamsAutoRecordPolicy()
    quickLeave.recordingStarted(automatically: true)
    precondition(
      quickLeave.observe(.noMeeting, at: start, isRecording: true, canStart: false) == nil)
    precondition(
      quickLeave.observe(.noMeeting, at: start + 0.4, isRecording: true, canStart: false) == nil)
    precondition(
      quickLeave.observe(.unknown, at: start + 0.6, isRecording: true, canStart: false) == nil)
    precondition(
      quickLeave.observe(.noMeeting, at: start + 1, isRecording: true, canStart: false) == nil)
    precondition(
      quickLeave.observe(.noMeeting, at: start + 2, isRecording: true, canStart: false) == .stop)
    var policy = TeamsAutoRecordPolicy()
    precondition(policy.observe(.noMeeting, at: start, isRecording: false, canStart: true) == nil)
    precondition(policy.observe(.inMeeting, at: start, isRecording: false, canStart: false) == nil)
    precondition(
      policy.observe(.inMeeting, at: start, isRecording: false, canStart: true) == .start)
    policy.recordingStarted(automatically: true)
    precondition(policy.observe(.unknown, at: start, isRecording: true, canStart: false) == nil)
    precondition(policy.observe(.noMeeting, at: start, isRecording: true, canStart: false) == nil)
    precondition(
      policy.observe(.inMeeting, at: start + grace, isRecording: true, canStart: false) == nil)
    let left = start + 2 * grace
    precondition(policy.observe(.noMeeting, at: left, isRecording: true, canStart: false) == nil)
    precondition(
      policy.observe(.noMeeting, at: left + grace, isRecording: true, canStart: false) == .stop)
    policy.recordingEnded()
    precondition(policy.observe(.inMeeting, at: left, isRecording: false, canStart: true) == .start)

    policy.recordingStarted(automatically: true)
    policy.recordingEnded()
    precondition(policy.observe(.inMeeting, at: start, isRecording: false, canStart: true) == nil)
    precondition(policy.observe(.noMeeting, at: start, isRecording: false, canStart: true) == nil)
    precondition(
      policy.observe(.inMeeting, at: start + 1, isRecording: false, canStart: true) == nil)
    precondition(
      policy.observe(.unknown, at: start + 2, isRecording: false, canStart: true) == nil)
    precondition(
      policy.observe(.inMeeting, at: start + 3, isRecording: false, canStart: true) == nil)
    precondition(
      policy.observe(.noMeeting, at: start + 4, isRecording: false, canStart: true) == nil)
    precondition(
      policy.observe(.noMeeting, at: start + 4 + grace, isRecording: false, canStart: true) == nil)
    precondition(
      policy.observe(.inMeeting, at: start + 5 + grace, isRecording: false, canStart: true)
        == .start)

    policy.recordingStarted(automatically: false)
    precondition(policy.observe(.noMeeting, at: start, isRecording: true, canStart: false) == nil)
    precondition(
      policy.observe(.noMeeting, at: start + grace, isRecording: true, canStart: false) == nil)

    for automatically in [false, true] {
      var stopped = TeamsAutoRecordPolicy()
      _ = stopped.observe(.inMeeting, at: start, isRecording: false, canStart: true)
      stopped.recordingStarted(automatically: automatically)
      _ = stopped.observe(.noMeeting, at: start + 1, isRecording: true, canStart: false)
      stopped.recordingEnded()
      precondition(!stopped.ownsRecording)
      precondition(stopped.waitingForMeetingEnd)
      precondition(
        stopped.observe(.inMeeting, at: start + 2, isRecording: false, canStart: true) == nil)
      _ = stopped.observe(.noMeeting, at: start + 3, isRecording: false, canStart: true)
      _ = stopped.observe(.noMeeting, at: start + 3 + grace, isRecording: false, canStart: true)
      precondition(!stopped.waitingForMeetingEnd)
      precondition(
        stopped.observe(.inMeeting, at: start + 4 + grace, isRecording: false, canStart: true)
          == .start)
    }
  }

  private static func writeTrack(at url: URL, muted: Bool) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let track = try CaptureTrack(url: url, start: 100)
    for block in 0..<10 {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
      buffer.frameLength = 4_410
      for index in 0..<4_410 {
        buffer.floatChannelData![0][index] =
          0.1 * sin(Float(index + block * 4_410) * 2 * .pi * 440 / 44_100)
      }
      try track.append(buffer, timestamp: 100 + Double(block) / 10, muted: muted)
    }
    try track.finish()
  }
}

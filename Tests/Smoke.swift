import AVFoundation
import Foundation
import ScreenCaptureKit

@main
struct Smoke {
  @MainActor
  static func main() async throws {
    for rate in [16_000.0, 44_100.0, 48_000.0] {
      let total = Int64(30.289 * rate)
      precondition(TranscriptionAudio.frameCount(remaining: total, sampleRate: rate) == total)
      let long = Int64(60.289 * rate)
      let first = TranscriptionAudio.frameCount(remaining: long, sampleRate: rate)
      precondition(first == Int64(30 * rate))
      precondition(
        TranscriptionAudio.frameCount(remaining: long - first, sampleRate: rate) == long - first)
    }
    let short: [Float] = [0.25, -0.25]
    let padded = TranscriptionAudio.pad(short, minimumCount: 4_800)
    precondition(padded.count == 4_800)
    precondition(Array(padded.prefix(short.count)) == short)
    precondition(padded.dropFirst(short.count).allSatisfy { $0 == 0 })
    precondition(TranscriptionAudio.pad(padded, minimumCount: 4_800) == padded)
    print("Transcription preserves short tails and pads short speaker turns: OK")
    let readyForScreen = PermissionSnapshot(
      microphone: true, screenRecording: false, accessibility: true)
    var continuation = ScreenPermissionContinuation()
    precondition(!continuation.consumeRequest(for: readyForScreen))
    continuation.waitingForAccessibility = true
    precondition(
      !continuation.consumeRequest(
        for: PermissionSnapshot(
          microphone: true, screenRecording: false, accessibility: false)))
    precondition(
      !continuation.consumeRequest(
        for: PermissionSnapshot(
          microphone: false, screenRecording: false, accessibility: true)))
    precondition(continuation.consumeRequest(for: readyForScreen))
    precondition(!continuation.consumeRequest(for: readyForScreen))
    continuation.waitingForAccessibility = true
    precondition(
      !continuation.consumeRequest(
        for: PermissionSnapshot(
          microphone: true, screenRecording: true, accessibility: true)))
    precondition(!continuation.consumeRequest(for: readyForScreen))
    print("Screen permission continuation: waits for prerequisites and requests only once: OK")
    precondition(
      PermissionSnapshot(microphone: false, screenRecording: false, accessibility: false).missing
        == [.microphone, .accessibility, .screenRecording])
    for microphone in [false, true] {
      for screen in [false, true] {
        for accessibility in [false, true] {
          let permissions = PermissionSnapshot(
            microphone: microphone, screenRecording: screen, accessibility: accessibility)
          precondition(permissions.recordingGranted == (microphone && screen && accessibility))
          precondition(permissions.missing.contains(.microphone) == !microphone)
          precondition(permissions.missing.contains(.screenRecording) == !screen)
          precondition(permissions.missing.contains(.accessibility) == !accessibility)
        }
      }
    }
    precondition(
      PermissionAccess.deniedPermission(for: PermissionRequired(permission: .microphone))
        == .microphone)
    precondition(
      PermissionAccess.deniedPermission(
        for: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        == .screenRecording)
    precondition(
      PermissionAccess.deniedPermission(
        for: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue))
        == nil)
    precondition(
      PermissionAccess.deniedPermission(for: MeetingError("Disk full")) == nil)
    print("All permission combinations and permission-only error classification: OK")
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
      "meeting-tests-\(UUID().uuidString)")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let stateDirectory = root.appendingPathComponent("state")
    let state = try StateStore(directory: stateDirectory)
    let date = Date(timeIntervalSince1970: 0)
    try state.update { $0.session = MeetingSession(startedAt: date, stem: "19700101T000000Z") }
    let recovered = try StateStore(directory: stateDirectory)
    precondition(recovered.state.session?.stem == "19700101T000000Z")
    try recovered.update {
      $0.session = nil
      $0.pendingAudio = "test.m4a"
    }
    let retried = try StateStore(directory: stateDirectory)
    precondition(retried.state.pendingAudio == "test.m4a")
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
    print("Local-time filenames, meeting titles, and mixed-format retention order: OK")
    func exists(_ folder: URL, _ name: String) -> Bool {
      manager.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
    try RecordingRetention.enforce(
      root: root, protectedStem: "19700101T000000Z", audioBudget: 40, transcriptBudget: 1_000)
    precondition(exists(audios, "19700101T000000Z.m4a"))
    precondition(!exists(audios, "19700101T000001Z.m4a"))
    precondition(exists(audios, "19700101T000002Z.m4a"))
    for stem in ["19700101T000000Z", "19700101T000001Z", "19700101T000002Z"] {
      precondition(exists(transcripts, stem + ".txt"))
    }
    try RecordingRetention.enforce(root: root, audioBudget: 10, transcriptBudget: 15)
    precondition(!exists(audios, "19700101T000000Z.m4a"))
    precondition(exists(audios, "19700101T000002Z.m4a"))
    precondition(!exists(transcripts, "19700101T000000Z.txt"))
    precondition(!exists(transcripts, "19700101T000001Z.txt"))
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
    for count in 0...2 {
      let configuration = NativeRecorder.configuration(teamsApplicationCount: count)
      precondition(configuration.capturesAudio == (count > 0))
      precondition(configuration.captureMicrophone)
    }
    precondition(
      TeamsMuteClassifier.classify([TeamsWindowSnapshot(buttons: [["Leave"], ["Unmute mic"]])])
        == .muted)
    precondition(
      TeamsMuteClassifier.classify([TeamsWindowSnapshot(buttons: [["Leave"], ["Mute mic"]])])
        == .unmuted)
    precondition(TeamsMuteState.muted.meetingPresence == .inMeeting)
    precondition(TeamsMuteState.unavailable(.noControl).meetingPresence == .inMeeting)
    precondition(TeamsMuteState.unavailable(.teamsClosed).meetingPresence == .noMeeting)
    precondition(TeamsMuteState.unavailable(.accessibilityError).meetingPresence == .unknown)
    testAutoRecordPolicy()
    print("Teams auto-record: starts, stops after grace, respects manual control: OK")

    let capture = root.appendingPathComponent("capture")
    try manager.createDirectory(at: capture, withIntermediateDirectories: true)
    try writeTrack(at: capture.appendingPathComponent("system.caf"), muted: false)
    try writeTrack(at: capture.appendingPathComponent("microphone.caf"), muted: true)
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
    try writeTrack(at: microphoneOnly.appendingPathComponent("microphone.caf"), muted: false)
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
      let text = try await NativeTranscriber().transcribe(
        file: URL(fileURLWithPath: CommandLine.arguments[2]),
        executable: URL(fileURLWithPath: CommandLine.arguments[3]))
      precondition(text.contains("Speaker 1:"))
      if CommandLine.arguments.count == 5 {
        let expected = Int(CommandLine.arguments[4])!
        let labels = Set(
          text.split(separator: "\n").compactMap { line -> String? in
            guard let start = line.range(of: "Speaker "),
              let end = line[start.upperBound...].firstIndex(of: ":")
            else { return nil }
            return String(line[start.upperBound..<end])
          })
        precondition(
          labels == Set((1...expected).map(String.init)), "Unexpected speaker count: \(labels)")
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
    let utc = TimeZone(secondsFromGMT: 0)!
    let epoch = Date(timeIntervalSince1970: 0)
    func stem() -> String {
      MeetingFiles.stem(for: epoch, in: audios, transcriptDirectory: transcripts, timeZone: utc)
    }
    precondition(stem() == "1970-01-01 00.00")
    try Data().write(to: transcripts.appendingPathComponent("1970-01-01 00.00 Weekly Sync.txt"))
    precondition(stem() == "1970-01-01 00.00-2")
    try manager.createDirectory(
      at: audios.appendingPathComponent(".1970-01-01 00.00-2.recording"),
      withIntermediateDirectories: true)
    precondition(stem() == "1970-01-01 00.00-3")

    precondition(
      MeetingFiles.date(fromStem: "1970-01-01 00.00-2 Weekly Sync", timeZone: utc) == epoch)
    precondition(MeetingFiles.date(fromStem: "19700101T000000Z-2") == epoch)
    precondition(MeetingFiles.date(fromStem: "1970-01-01 00.00Weekly") == nil)
    precondition(MeetingFiles.date(fromStem: "keep-me") == nil)

    precondition(MeetingFiles.titleComponent("  Sync 1:1 / Team  ") == "Sync 1-1 - Team")
    precondition(MeetingFiles.titleComponent("A\nB") == "A-B")
    precondition(MeetingFiles.titleComponent("..hidden") == "hidden")
    precondition(MeetingFiles.titleComponent("   ") == nil)
    precondition(MeetingFiles.titleComponent(String(repeating: "a", count: 200))?.count == 80)
    precondition(
      MeetingSession(startedAt: epoch, stem: "1970-01-01 00.00", title: "Weekly Sync").fileStem
        == "1970-01-01 00.00 Weekly Sync")
    let legacyState = #"{"session":{"startedAt":0,"stem":"19700101T000000Z"}}"#
    let decoded = try JSONDecoder().decode(MeetingState.self, from: Data(legacyState.utf8))
    precondition(decoded.session?.title == nil && decoded.session?.fileStem == "19700101T000000Z")

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
    for name in ["20260928T073121Z", "2026-09-29 14.42 A", "2026-09-30 09.00 B"] {
      try Data(repeating: 1, count: 20).write(
        to: retainedAudios.appendingPathComponent(name + ".m4a"))
    }
    try RecordingRetention.enforce(root: retention, audioBudget: 45)
    precondition(
      !manager.fileExists(
        atPath: retainedAudios.appendingPathComponent("20260928T073121Z.m4a").path))
    precondition(
      manager.fileExists(
        atPath: retainedAudios.appendingPathComponent("2026-09-29 14.42 A.m4a").path))
    precondition(
      manager.fileExists(
        atPath: retainedAudios.appendingPathComponent("2026-09-30 09.00 B.m4a").path))
  }

  private static func testAutoRecordPolicy() {
    let start = Date(timeIntervalSince1970: 0)
    let grace = TeamsAutoRecordPolicy.leaveGracePeriod
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
      policy.observe(.inMeeting, at: start, isRecording: false, canStart: true) == .start)

    policy.recordingStarted(automatically: false)
    precondition(policy.observe(.noMeeting, at: start, isRecording: true, canStart: false) == nil)
    precondition(
      policy.observe(.noMeeting, at: start + grace, isRecording: true, canStart: false) == nil)
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
  }
}

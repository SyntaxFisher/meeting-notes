import AVFoundation
import Foundation

private final class FixtureMicrophoneEngine: MicrophoneEngine {
  var isRunning = false
  var startError: Error?
  var samples: [(AVAudioPCMBuffer, Double)] = []
  var starts = 0
  var stops = 0
  var onStart: (() -> Void)?
  private var receive: AudioCaptureHandler?
  private var change: (@Sendable () -> Void)?

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler,
    onConfigurationChange: @escaping @Sendable () -> Void
  ) throws {
    starts += 1
    self.receive = receive
    change = onConfigurationChange
    if let startError { throw startError }
    isRunning = true
    for (buffer, time) in samples {
      receive(
        try CapturedAudio.copy(buffer.audioBufferList, format: buffer.format),
        AVAudioTime.hostTime(forSeconds: time))
    }
    onStart?()
  }

  func configurationChanged() {
    isRunning = false
    change?()
  }

  func stop() {
    stops += 1
    isRunning = false
  }
}

private final class FixtureAudioInput: AudioCaptureInput {
  let source: CaptureSource
  var startError: Error?
  var stopError: Error?
  var samples: [(AVAudioPCMBuffer, Double)] = []
  var starts = 0
  var stops = 0
  var onStart: (() -> Void)?
  var receive: AudioCaptureHandler?
  var fail: AudioCaptureFailureHandler?

  init(_ source: CaptureSource) { self.source = source }

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  )
    throws
  {
    starts += 1
    self.receive = receive
    fail = onFailure
    onStart?()
    for (buffer, seconds) in samples { emit(buffer, at: seconds) }
    if let startError { throw startError }
  }

  func emit(_ buffer: AVAudioPCMBuffer, at seconds: Double) {
    let owned = try! CapturedAudio.copy(buffer.audioBufferList, format: buffer.format)
    receive?(owned, AVAudioTime.hostTime(forSeconds: seconds))
  }

  func stop() throws {
    stops += 1
    if let stopError { throw stopError }
  }
}

extension Smoke {
  static func testAudioCapture(root: URL) async throws {
    testSystemAudioScope()
    testStoredAudioScopes()
    precondition(NativeRecorder.captureInputs(systemAudio: nil).map(\.source) == [.microphone])
    for scope in [SystemAudioScope.teams, .deviceAudio, .app("us.zoom.xos")] {
      let inputs = NativeRecorder.captureInputs(systemAudio: scope)
      precondition(inputs.map(\.source) == [.microphone, .system])
      precondition((inputs[1] as? SystemAudioCapture)?.scope == scope)
    }
    // Before Teams opens audio there is no process object, so the tap falls back to the bundle.
    let description = SystemAudioCapture.appTapDescription(scope: .teams, processes: [])
    precondition(description.bundleIDs == ["com.microsoft.teams2"])
    precondition(description.processes.isEmpty && !description.isExclusive)
    precondition(description.isPrivate && description.isMixdown && description.isMono)
    precondition(description.isProcessRestoreEnabled && description.muteBehavior == .unmuted)
    testTeamsTapTargets()

    let resources = AudioCaptureResources()
    var released: [Int] = []
    resources.add { released.append(1) }
    resources.add {
      released.append(2)
      throw MeetingError("Fixture cleanup failure")
    }
    resources.add { released.append(3) }
    do {
      try resources.release()
      preconditionFailure("Cleanup must report its failure")
    } catch {}
    try resources.release()
    precondition(released == [3, 2, 1])

    for interleaved in [false, true] {
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
        interleaved: interleaved)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
      buffer.frameLength = 480
      for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        memset(channel.mData!, 1, Int(channel.mDataByteSize))
      }
      let owned = try CapturedAudio.copy(buffer.audioBufferList, format: format).buffer
      for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        memset(channel.mData!, 0, Int(channel.mDataByteSize))
      }
      for channel in UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList) {
        precondition(channel.mData!.load(as: UInt8.self) == 1)
      }
      precondition(owned.frameLength == 480 && owned.format == format)
    }

    let system = FixtureAudioInput(.system)
    let microphone = FixtureAudioInput(.microphone)
    system.samples = [(tone(rate: 48_000), 100)]
    microphone.samples = [(tone(rate: 44_100), 100.5)]
    let directory = root.appendingPathComponent("mixed")
    let recorder = NativeRecorder(
      directory: directory, systemAudio: .deviceAudio, makeInputs: { [system, microphone] },
      checkPermission: {})
    recorder.setMicrophoneMuted(true)
    try await recorder.start()
    recorder.setMicrophoneMuted(false)
    microphone.emit(tone(rate: 48_000, channels: 2), at: 101.5)
    try await recorder.stop()
    try await recorder.stop()
    precondition(system.starts == 1 && microphone.starts == 1)
    precondition(system.stops == 1 && microphone.stops == 1)
    let manifestJSON = try String(
      contentsOf: directory.appendingPathComponent("capture.json"), encoding: .utf8)
    precondition(manifestJSON.contains("\"systemAudio\":\"device-audio\""))
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("capture.json"))
    )
    precondition(abs(manifest.systemStart! - 100) < 0.0001)
    precondition(abs(manifest.microphoneStart! - 100.5) < 0.0001)
    precondition(manifest.systemAudio == .deviceAudio)
    let systemAudio = try readSamples(directory.appendingPathComponent("system.aac"))
    let microphoneAudio = try readSamples(directory.appendingPathComponent("microphone.aac"))
    precondition(energy(systemAudio, from: 5_000, to: 40_000) > 100)
    precondition(energy(microphoneAudio, from: 5_000, to: 40_000) < 0.01)
    precondition(energy(microphoneAudio, from: 55_000, to: 85_000) > 100)
    precondition(abs(microphoneAudio.count - 96_000) < 2_000)
    try await testAppCapture(root: root)
    let savedTrack = try Data(contentsOf: directory.appendingPathComponent("microphone.aac"))
    microphone.emit(tone(rate: 48_000), at: 103)
    microphone.fail?(MeetingError("Late callback"))
    try await recorder.stop()
    let unchanged = try Data(contentsOf: directory.appendingPathComponent("microphone.aac"))
    precondition(unchanged == savedTrack)
    let output = root.appendingPathComponent("mixed.m4a")
    try NativeRecorder.mix(directory: directory, destination: output)
    let mixed = try AVAudioFile(forReading: output)
    precondition(abs(Double(mixed.length) / mixed.processingFormat.sampleRate - 2.5) < 0.1)

    let duplicate = NativeRecorder(
      directory: directory, makeInputs: { [microphone] }, checkPermission: {})
    do {
      try await duplicate.start()
      preconditionFailure("Existing capture files must be protected")
    } catch {}
    precondition(microphone.starts == 1)
    let protectedTrack = try Data(contentsOf: directory.appendingPathComponent("microphone.aac"))
    precondition(protectedTrack == savedTrack)

    let alone = FixtureAudioInput(.microphone)
    alone.samples = [(tone(rate: 48_000), 200)]
    let aloneDirectory = root.appendingPathComponent("microphone-only")
    let aloneRecorder = NativeRecorder(
      directory: aloneDirectory, makeInputs: { [alone] }, checkPermission: {})
    try await aloneRecorder.start()
    precondition(aloneRecorder.meetingSource == .microphone)
    try await aloneRecorder.stop()
    precondition(
      !FileManager.default.fileExists(
        atPath: aloneDirectory.appendingPathComponent("system.aac").path))
    try NativeRecorder.mix(
      directory: aloneDirectory, destination: root.appendingPathComponent("alone.m4a"))

    let completedAudio = root.appendingPathComponent("alone.m4a")
    let completedBytes = try Data(contentsOf: completedAudio)
    for failsOnStop in [false, true] {
      let discardedInput = FixtureAudioInput(.microphone)
      discardedInput.samples = [(tone(rate: 48_000), 100)]
      if failsOnStop { discardedInput.stopError = MeetingError("Fixture stop failure") }
      let discardedDirectory = root.appendingPathComponent("discard-\(failsOnStop)")
      let discarded = NativeRecorder(
        directory: discardedDirectory, makeInputs: { [discardedInput] }, checkPermission: {})
      try await discarded.start()
      try await discarded.discard()
      precondition(discardedInput.stops == 1)
      precondition(!FileManager.default.fileExists(atPath: discardedDirectory.path))
      discardedInput.emit(tone(rate: 48_000), at: 102)
      try await discarded.discard()
      precondition(discardedInput.stops == 1)
      precondition(!FileManager.default.fileExists(atPath: discardedDirectory.path))
      let preservedBytes = try Data(contentsOf: completedAudio)
      precondition(preservedBytes == completedBytes)
    }

    let first = FixtureAudioInput(.system)
    let second = FixtureAudioInput(.microphone)
    second.startError = MeetingError("Fixture startup failure")
    first.stopError = MeetingError("Fixture stop failure")
    let failed = NativeRecorder(
      directory: root.appendingPathComponent("failed"), makeInputs: { [first, second] },
      checkPermission: {})
    do {
      try await failed.start()
      preconditionFailure("Startup failure must propagate")
    } catch {
      precondition(error.localizedDescription == "Fixture startup failure")
    }
    try await failed.stop()
    precondition(first.stops == 1 && second.stops == 1)

    let forbidden = FixtureAudioInput(.microphone)
    let unapproved = NativeRecorder(
      directory: root.appendingPathComponent("denied"), makeInputs: { [forbidden] },
      checkPermission: { throw PermissionRequired(permission: .microphone) })
    do {
      try await unapproved.start()
      preconditionFailure("Permission failure must propagate")
    } catch {
      precondition(PermissionAccess.deniedPermission(for: error) == .microphone)
    }
    precondition(forbidden.starts == 0 && forbidden.stops == 0)

    let interrupted = FixtureAudioInput(.microphone)
    let enteredStart = DispatchSemaphore(value: 0)
    let finishStart = DispatchSemaphore(value: 0)
    interrupted.onStart = {
      enteredStart.signal()
      precondition(finishStart.wait(timeout: .now() + 5) == .success)
    }
    let cancelled = NativeRecorder(
      directory: root.appendingPathComponent("cancelled"), makeInputs: { [interrupted] },
      checkPermission: {})
    let task = Task.detached { try await cancelled.start() }
    precondition(enteredStart.wait(timeout: .now() + 5) == .success)
    task.cancel()
    finishStart.signal()
    do {
      try await task.value
      preconditionFailure("Cancelled startup must stop its input")
    } catch {
      precondition(error is CancellationError)
    }
    precondition(interrupted.stops == 1)

    let broken = FixtureAudioInput(.microphone)
    let runtimeFailure = NativeRecorder(
      directory: root.appendingPathComponent("runtime-failure"), makeInputs: { [broken] },
      checkPermission: {})
    try await runtimeFailure.start()
    broken.fail?(MeetingError("Fixture callback failure"))
    do {
      try await runtimeFailure.stop()
      preconditionFailure("Callback failure must reach the caller")
    } catch {
      precondition(error.localizedDescription == "Fixture callback failure")
    }
    precondition(broken.stops == 1)
    try await testMicrophoneRecovery(root: root)
    testCaptureHealth()
    print("Audio-only sources, owned buffers, mute, timestamps, format changes and cleanup: OK")
  }

  private static func testMicrophoneRecovery(root: URL) async throws {
    let old = FixtureMicrophoneEngine()
    old.samples = [(tone(rate: 24_000), 100)]
    let changing = FixtureMicrophoneEngine()
    changing.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
    let fresh = FixtureMicrophoneEngine()
    fresh.samples = [(tone(rate: 48_000, channels: 2), 101)]
    let recovered = DispatchSemaphore(value: 0)
    fresh.onStart = { recovered.signal() }
    let engines = [old, changing, fresh]
    var next = 0
    let microphone = MicrophoneCapture(retryDelays: [0, 0, 0]) {
      precondition(next < engines.count)
      defer { next += 1 }
      return engines[next]
    }
    let directory = root.appendingPathComponent("bluetooth-format-change")
    let recorder = NativeRecorder(
      directory: directory, makeInputs: { [microphone] }, checkPermission: {})
    try await recorder.start()
    old.configurationChanged()
    precondition(recovered.wait(timeout: .now() + 5) == .success)
    try await recorder.stop()
    try await recorder.stop()
    precondition(engines.allSatisfy { $0.starts == 1 && $0.stops == 1 })
    let audio = try readSamples(directory.appendingPathComponent("microphone.aac"))
    precondition(abs(audio.count - 96_000) < 2_000)
    precondition(energy(audio, from: 5_000, to: 40_000) > 100)
    precondition(energy(audio, from: 55_000, to: 85_000) > 100)
    old.configurationChanged()
    fresh.configurationChanged()
    try microphone.stop()
    precondition(next == 3)

    let disconnected = FixtureMicrophoneEngine()
    disconnected.startError = MicrophoneInputUnavailable()
    let reconnected = FixtureMicrophoneEngine()
    var reconnectAttempt = 0
    let reconnecting = MicrophoneCapture(retryDelays: [0]) {
      defer { reconnectAttempt += 1 }
      return reconnectAttempt == 0 ? disconnected : reconnected
    }
    try reconnecting.start(receive: { _, _ in }, onFailure: { _ in })
    try reconnecting.stop()
    precondition(reconnectAttempt == 2 && disconnected.stops == 1 && reconnected.stops == 1)

    let denied = FixtureMicrophoneEngine()
    denied.startError = PermissionRequired(permission: .microphone)
    let deniedCapture = MicrophoneCapture(retryDelays: [0, 0]) { denied }
    do {
      try deniedCapture.start(receive: { _, _ in }, onFailure: { _ in })
      preconditionFailure("Microphone permission denial must fail without retrying")
    } catch {
      precondition(PermissionAccess.deniedPermission(for: error) == .microphone)
    }
    try deniedCapture.stop()
    precondition(denied.starts == 1 && denied.stops == 1)

    let initial = FixtureMicrophoneEngine()
    let failingEngines = (0..<3).map { _ in
      let engine = FixtureMicrophoneEngine()
      engine.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
      return engine
    }
    let failing = [initial] + failingEngines
    var index = 0
    let bounded = MicrophoneCapture(retryDelays: [0, 0, 0]) {
      precondition(index < failing.count)
      defer { index += 1 }
      return failing[index]
    }
    let failure = DispatchSemaphore(value: 0)
    try bounded.start(receive: { _, _ in }, onFailure: { _ in failure.signal() })
    initial.configurationChanged()
    precondition(failure.wait(timeout: .now() + 5) == .success)
    try bounded.stop()
    precondition(index == 4 && failing.allSatisfy { $0.stops == 1 })

    let pending = FixtureMicrophoneEngine()
    var creations = 0
    let cancelled = MicrophoneCapture(retryDelays: [0.1]) {
      creations += 1
      return pending
    }
    let unexpectedFailure = DispatchSemaphore(value: 0)
    try cancelled.start(receive: { _, _ in }, onFailure: { _ in unexpectedFailure.signal() })
    pending.configurationChanged()
    try cancelled.stop()
    precondition(unexpectedFailure.wait(timeout: .now() + 0.2) == .timedOut)
    try cancelled.stop()
    precondition(creations == 1 && pending.stops == 1)
    print(
      "Bluetooth 24 kHz to 48 kHz recovery, fresh engines, bounded retries and cancellation: OK")
  }

  private static func testTeamsTapTargets() {
    let moduleHost = AudioProcessStatus(
      id: 101, pid: 61878, bundleID: "com.microsoft.teams2.modulehost",
      outputActive: true, outputDevices: [96])
    let helper = AudioProcessStatus(
      id: 102, pid: 61885, bundleID: "com.microsoft.teams2.helper",
      outputActive: false, outputDevices: [])
    let unrelated = AudioProcessStatus(
      id: 103, pid: 70000, bundleID: "com.apple.Music",
      outputActive: true, outputDevices: [96])
    let similarName = AudioProcessStatus(
      id: 104, pid: 70001, bundleID: "com.microsoft.teams20",
      outputActive: true, outputDevices: [96])
    let description = SystemAudioCapture.appTapDescription(
      scope: .teams, processes: [moduleHost, helper, unrelated, similarName])
    precondition(description.name == "Meeting Notes Teams audio")
    precondition(description.processes == [101, 102] && description.bundleIDs.isEmpty)
    precondition(!description.isExclusive && description.muteBehavior == .unmuted)
    precondition(description.isMixdown && description.isMono && description.isPrivate)

    // An idle module host and the one playing the meeting share a bundle ID; tap both.
    let idleHost = AudioProcessStatus(
      id: 99, pid: 50320, bundleID: moduleHost.bundleID, outputActive: false, outputDevices: [])
    precondition(
      SystemAudioCapture.tapTargets(of: .teams, in: [moduleHost, idleHost, helper]) == [
        99, 101, 102,
      ])

    let initial = SystemAudioCapture.tapTargets(of: .teams, in: [helper])
    let joined = SystemAudioCapture.tapTargets(of: .teams, in: [helper, moduleHost])
    precondition(initial == [102] && joined == [101, 102])
    precondition(SystemAudioCapture.tapTargets(of: .teams, in: [helper, helper]) == initial)
    precondition(
      SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: [], previous: nil, current: [helper]))
    precondition(
      !SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: [], previous: nil, current: [unrelated]))
    precondition(
      SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: initial, previous: [helper], current: [helper, moduleHost]))
    precondition(
      !SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: joined, previous: [helper, moduleHost],
        current: [helper, moduleHost]))
    precondition(
      SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: joined, previous: [helper, moduleHost], current: [helper]))
    let restartedHost = AudioProcessStatus(
      id: 105, pid: 70002, bundleID: moduleHost.bundleID,
      outputActive: false, outputDevices: [])
    precondition(
      SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: joined, previous: [helper, moduleHost],
        current: [helper, restartedHost]))
    let reroutedHost = AudioProcessStatus(
      id: moduleHost.id, pid: moduleHost.pid, bundleID: moduleHost.bundleID,
      outputActive: true, outputDevices: [148])
    precondition(
      SystemAudioCapture.needsRestart(
        scope: .teams, tappedProcesses: joined, previous: [helper, moduleHost],
        current: [helper, reroutedHost]))
    print(
      "Teams process taps, duplicate module hosts, helper changes and app isolation: OK")
  }

  private static func testSystemAudioScope() {
    // Auto-record only starts in a Teams meeting and always taps Teams alone.
    for presence in [TeamsMeetingPresence.inMeeting, .noMeeting, .unknown] {
      precondition(SystemAudioScope.forRecording(automatic: true, teamsMeeting: presence) == .teams)
    }
    precondition(
      SystemAudioScope.forRecording(automatic: false, teamsMeeting: .inMeeting) == .teams)
    precondition(
      SystemAudioScope.forRecording(automatic: false, teamsMeeting: .noMeeting) == .deviceAudio)
    precondition(
      SystemAudioScope.forRecording(automatic: false, teamsMeeting: .unknown) == .deviceAudio)
    // Teams running without a meeting, or closed, counts as no meeting.
    for state in [TeamsMuteState.unavailable(.noMeeting), .unavailable(.teamsClosed)] {
      precondition(
        SystemAudioScope.forRecording(automatic: false, teamsMeeting: state.meetingPresence)
          == .deviceAudio)
    }
    precondition(
      SystemAudioScope.forRecording(
        automatic: false, teamsMeeting: TeamsMuteState.muted.meetingPresence)
        == .teams)
    precondition(SystemAudioScope.teams.mode == "microphone-and-teams")
    precondition(SystemAudioScope.deviceAudio.mode == "microphone-and-device-audio")
    precondition(MeetingSource(.deviceAudio) == .deviceAudio && MeetingSource(nil) == .microphone)

    let global = SystemAudioCapture.deviceTapDescription(ownProcess: 42)
    precondition(global.isExclusive && global.processes == [42], "Taps all but this app")
    precondition(global.bundleIDs.isEmpty && global.isMono && global.isMixdown)
    precondition(global.isPrivate && global.muteBehavior == .unmuted)
    precondition(global.name == "Meeting Notes device audio")
    let unexcluded = SystemAudioCapture.deviceTapDescription(ownProcess: nil)
    precondition(unexcluded.isExclusive && unexcluded.processes.isEmpty)

    // Teams process changes never rebuild a global tap.
    let teams = AudioProcessStatus(
      id: 101, pid: 61878, bundleID: "com.microsoft.teams2.modulehost",
      outputActive: true, outputDevices: [96])
    let music = AudioProcessStatus(
      id: 103, pid: 70000, bundleID: "com.apple.Music", outputActive: true, outputDevices: [148])
    precondition(
      !SystemAudioCapture.needsRestart(
        scope: .deviceAudio, tappedProcesses: [], previous: [music], current: [music, teams]))
    precondition(
      !SystemAudioCapture.needsRestart(
        scope: .deviceAudio, tappedProcesses: [], previous: [teams], current: []))
    print("Recording source decision, global device-audio tap excluding this app: OK")
  }

  private static func testStoredAudioScopes() {
    for scope in [SystemAudioScope.teams, .deviceAudio, .app("us.zoom.xos")] {
      precondition(SystemAudioScope(rawValue: scope.rawValue) == scope)
      precondition(MeetingSource(rawValue: MeetingSource(scope).rawValue) == MeetingSource(scope))
    }
    precondition(SystemAudioScope.app("us.zoom.xos").rawValue == "app:us.zoom.xos")
    precondition(SystemAudioScope.app("us.zoom.xos").mode == "microphone-and-app:us.zoom.xos")
    for invalid in ["app:", "app:zoom", "zoom", "app:us zoom.xos", "microphone"] {
      precondition(SystemAudioScope(rawValue: invalid) == nil, invalid)
    }
    precondition(MeetingSource(rawValue: "microphone") == .microphone)
    precondition(MeetingSource(rawValue: "app:us.zoom.xos")?.systemAudio == .app("us.zoom.xos"))
    precondition(MeetingSource.microphone.summary == "microphone only")
    precondition(
      MeetingSource.app("com.example.call").summary == "com.example.call audio + microphone")

    // An app tap covers the app and its helpers, never a lookalike bundle ID.
    let call = AudioProcessStatus(
      id: 201, pid: 800, bundleID: "com.example.call", outputActive: true, outputDevices: [96])
    let helper = AudioProcessStatus(
      id: 202, pid: 801, bundleID: "com.example.call.helper", outputActive: false,
      outputDevices: [])
    let lookalike = AudioProcessStatus(
      id: 203, pid: 802, bundleID: "com.example.caller", outputActive: true, outputDevices: [96])
    let music = AudioProcessStatus(
      id: 204, pid: 803, bundleID: "com.apple.Music", outputActive: true, outputDevices: [96])
    let scope = SystemAudioScope.app("com.example.call")
    let tap = SystemAudioCapture.appTapDescription(
      scope: scope, processes: [call, helper, lookalike, music])
    precondition(tap.processes == [201, 202] && tap.bundleIDs.isEmpty)
    precondition(!tap.isExclusive && tap.isMixdown && tap.isMono && tap.isPrivate)
    precondition(tap.muteBehavior == .unmuted)
    precondition(tap.name == "Meeting Notes com.example.call audio")
    // Before the app runs or opens audio, the tap waits for its bundle ID.
    let waiting = SystemAudioCapture.appTapDescription(scope: scope, processes: [music])
    precondition(waiting.bundleIDs == ["com.example.call"] && waiting.processes.isEmpty)
    precondition(waiting.isProcessRestoreEnabled)
    precondition(
      SystemAudioScope.app("com.apple.Safari").bundleIDs
        == ["com.apple.Safari"])
    let webKit = AudioProcessStatus(
      id: 205, pid: 804, bundleID: "com.apple.WebKit.GPU", outputActive: true, outputDevices: [96])
    precondition(
      SystemAudioCapture.tapTargets(of: .app("com.apple.Safari"), in: [webKit, call]).isEmpty)
    let sharedCall = AudioProcessStatus(
      id: 206, pid: 805, bundleID: "com.apple.avconferenced", outputActive: true,
      outputDevices: [96])
    precondition(
      SystemAudioCapture.tapTargets(of: .app("com.apple.FaceTime"), in: [sharedCall, call]).isEmpty)
    precondition(
      SystemAudioCapture.needsRestart(
        scope: scope, tappedProcesses: [], previous: nil, current: [call]))
    precondition(
      !SystemAudioCapture.needsRestart(
        scope: scope, tappedProcesses: [], previous: nil, current: [music]))
    precondition(
      !SystemAudioCapture.needsRestart(
        scope: scope, tappedProcesses: [201], previous: [call], current: [call]))
    precondition(
      SystemAudioCapture.needsRestart(
        scope: scope, tappedProcesses: [201], previous: [call], current: [call, helper]))
    print("Recording source choices, app helpers and exclusion of shared audio services: OK")
  }

  /// An app recording names the app in capture.json and in the meeting source.
  private static func testAppCapture(root: URL) async throws {
    let system = FixtureAudioInput(.system)
    let microphone = FixtureAudioInput(.microphone)
    let directory = root.appendingPathComponent("app")
    let recorder = NativeRecorder(
      directory: directory, systemAudio: .app("us.zoom.xos"),
      makeInputs: { [system, microphone] }, checkPermission: {})
    try await recorder.start()
    precondition(recorder.meetingSource == .app("us.zoom.xos"))
    system.emit(tone(rate: 48_000), at: 200)
    microphone.emit(tone(rate: 48_000), at: 200)
    try await recorder.stop()
    let data = try Data(contentsOf: directory.appendingPathComponent("capture.json"))
    precondition(
      String(decoding: data, as: UTF8.self).contains("\"systemAudio\":\"app:us.zoom.xos\""))
    let manifest = try JSONDecoder().decode(CaptureManifest.self, from: data)
    precondition(manifest.systemAudio == .app("us.zoom.xos"))

    let microphoneOnly = NativeRecorder(
      directory: root.appendingPathComponent("microphone-only"), systemAudio: nil,
      makeInputs: { [FixtureAudioInput(.microphone)] }, checkPermission: {})
    try await microphoneOnly.start()
    precondition(microphoneOnly.meetingSource == .microphone)
    try await microphoneOnly.stop()
  }

  private static func testCaptureHealth() {
    var health = SystemCaptureHealth()
    precondition(health.check(outputActive: false, at: 0) == .wait)
    precondition(health.check(outputActive: false, at: 100) == .wait)
    precondition(health.check(outputActive: true, at: 101) == .wait)
    precondition(health.check(outputActive: true, at: 105) == .wait)
    precondition(health.check(outputActive: true, at: 106) == .restart)
    precondition(health.check(outputActive: true, at: 111) == .restart)
    precondition(health.check(outputActive: true, at: 116) == .fail)
    health.receivedBuffer()
    precondition(health.restarts == 0)
    precondition(health.check(outputActive: true, at: 120) == .wait)
    health.receivedBuffer()
    precondition(health.check(outputActive: true, at: 126) == .wait)
    precondition(health.check(outputActive: false, at: 200) == .wait)
    precondition(health.check(outputActive: true, at: 300) == .wait)

    var stats = CaptureSignalStatistics()
    stats.received(frames: 480, peak: 0, muted: false)
    precondition(stats.buffers == 1 && stats.inputPeak == 0 && stats.recordedPeak == 0)
    stats.received(frames: 480, peak: 0.5, muted: true)
    precondition(stats.inputPeak == 0.5 && stats.recordedPeak == 0 && stats.mutedFrames == 480)
    stats.received(frames: 480, peak: 0.25, muted: false)
    precondition(stats.recordedPeak == 0.25 && stats.frames == 1_440)
    print("Missing Teams buffers, bounded restart policy, silence and mute signal diagnostics: OK")
  }

  private static func tone(rate: Double, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<Int(channels) {
      for index in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![channel][index] =
          0.1 * sin(Float(index) * 2 * .pi * 440 / Float(rate))
      }
    }
    return buffer
  }

  private static func readSamples(_ url: URL) throws -> [Float] {
    try trackSamples(url)
  }

  private static func energy(_ samples: [Float], from start: Int, to end: Int) -> Float {
    precondition(samples.count >= end)
    return samples[start..<end].reduce(0) { $0 + abs($1) }
  }
}

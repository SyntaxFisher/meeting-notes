import AVFoundation
import Foundation

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
    precondition(NativeRecorder.captureInputs(teamsRunning: false).map(\.source) == [.microphone])
    precondition(
      NativeRecorder.captureInputs(teamsRunning: true).map(\.source) == [.system, .microphone])
    let description = TeamsAudioCapture.tapDescription()
    precondition(description.bundleIDs == ["com.microsoft.teams2"])
    precondition(description.processes.isEmpty && !description.isExclusive)
    precondition(description.isPrivate && description.isMixdown && description.isMono)
    precondition(description.isProcessRestoreEnabled && description.muteBehavior == .unmuted)

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
      directory: directory, makeInputs: { [system, microphone] }, checkPermission: {})
    recorder.setMicrophoneMuted(true)
    try await recorder.start()
    recorder.setMicrophoneMuted(false)
    microphone.emit(tone(rate: 48_000, channels: 2), at: 101.5)
    try await recorder.stop()
    try await recorder.stop()
    precondition(system.starts == 1 && microphone.starts == 1)
    precondition(system.stops == 1 && microphone.stops == 1)
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("capture.json"))
    )
    precondition(abs(manifest.systemStart! - 100) < 0.0001)
    precondition(abs(manifest.microphoneStart! - 100.5) < 0.0001)
    let systemAudio = try readSamples(directory.appendingPathComponent("system.caf"))
    let microphoneAudio = try readSamples(directory.appendingPathComponent("microphone.caf"))
    precondition(energy(systemAudio, from: 5_000, to: 40_000) > 100)
    precondition(energy(microphoneAudio, from: 5_000, to: 40_000) < 0.01)
    precondition(energy(microphoneAudio, from: 55_000, to: 85_000) > 100)
    precondition(abs(microphoneAudio.count - 96_000) < 2_000)
    let savedTrack = try Data(contentsOf: directory.appendingPathComponent("microphone.caf"))
    microphone.emit(tone(rate: 48_000), at: 103)
    microphone.fail?(MeetingError("Late callback"))
    try await recorder.stop()
    let unchanged = try Data(contentsOf: directory.appendingPathComponent("microphone.caf"))
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
    let protectedTrack = try Data(contentsOf: directory.appendingPathComponent("microphone.caf"))
    precondition(protectedTrack == savedTrack)

    let alone = FixtureAudioInput(.microphone)
    alone.samples = [(tone(rate: 48_000), 200)]
    let aloneDirectory = root.appendingPathComponent("microphone-only")
    let aloneRecorder = NativeRecorder(
      directory: aloneDirectory, makeInputs: { [alone] }, checkPermission: {})
    try await aloneRecorder.start()
    try await aloneRecorder.stop()
    precondition(
      !FileManager.default.fileExists(
        atPath: aloneDirectory.appendingPathComponent("system.caf").path))
    try NativeRecorder.mix(
      directory: aloneDirectory, destination: root.appendingPathComponent("alone.m4a"))

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
    print("Audio-only sources, owned buffers, mute, timestamps, format changes and cleanup: OK")
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
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  private static func energy(_ samples: [Float], from start: Int, to end: Int) -> Float {
    precondition(samples.count >= end)
    return samples[start..<end].reduce(0) { $0 + abs($1) }
  }
}

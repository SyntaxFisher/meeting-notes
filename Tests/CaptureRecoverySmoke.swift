import AVFoundation
import Foundation

private final class ScriptedInput: AudioCaptureInput {
  let source: CaptureSource
  private let chunks: [(AVAudioPCMBuffer, Double)]

  init(_ source: CaptureSource, _ chunks: [(AVAudioPCMBuffer, Double)]) {
    self.source = source
    self.chunks = chunks
  }

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  ) throws {
    for (buffer, seconds) in chunks {
      receive(
        try CapturedAudio.copy(buffer.audioBufferList, format: buffer.format),
        AVAudioTime.hostTime(forSeconds: seconds))
    }
  }

  func stop() throws {}
}

/// Fixture meeting: short tone bursts at known host times on both tracks, so a recovered mix
/// can be checked for duration and for the relative timing of the two tracks.
private enum MarkerMeeting {
  static let systemStart = 100.0
  static let microphoneStart = 100.75
  static let duration = 20.0
  static let burst = 0.05
  static let systemMarkers = stride(from: 101.0, to: 120, by: 1).map { $0 }
  static let microphoneMarkers = stride(from: 101.5, to: 120.7, by: 1).map { $0 }
  static var manifest: CaptureManifest {
    CaptureManifest(systemStart: systemStart, microphoneStart: microphoneStart)
  }

  static var system: [(AVAudioPCMBuffer, Double)] {
    chunks(start: systemStart, markers: systemMarkers) { _ in (48_000, 1) }
  }

  /// A Bluetooth-style microphone that switches from 24 kHz mono to 48 kHz stereo halfway.
  static var microphone: [(AVAudioPCMBuffer, Double)] {
    chunks(start: microphoneStart, markers: microphoneMarkers) {
      $0 < microphoneStart + duration / 2 ? (24_000, 1) : (48_000, 2)
    }
  }

  private static func chunks(
    start: Double, markers: [Double], format: (Double) -> (Double, AVAudioChannelCount)
  ) -> [(AVAudioPCMBuffer, Double)] {
    var result: [(AVAudioPCMBuffer, Double)] = []
    var time = start
    while time < start + duration - 0.0001 {
      let (rate, channels) = format(time)
      let buffer = AVAudioPCMBuffer(
        pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!,
        frameCapacity: AVAudioFrameCount(rate / 100))!
      buffer.frameLength = buffer.frameCapacity
      for index in 0..<Int(buffer.frameLength) {
        let sampleTime = time + Double(index) / rate
        let since = markers.map { sampleTime - $0 }.first { $0 >= 0 && $0 < burst }
        let value = since.map { Float(0.5 * sin(2 * .pi * 1_000 * $0)) } ?? 0
        for channel in 0..<Int(channels) { buffer.floatChannelData![channel][index] = value }
      }
      result.append((buffer, time))
      time += Double(buffer.frameLength) / rate
    }
    return result
  }
}

extension Smoke {
  static let captureUntilKilledFlag = "--capture-until-killed"

  /// Child process of the kill test: records the fixture meeting, reports once its audio
  /// reached the files, and waits to be killed without ever stopping the recorder.
  static func captureUntilKilled(directory: URL, ready: URL) async throws -> Never {
    let recorder = NativeRecorder(
      directory: directory,
      makeInputs: {
        [
          ScriptedInput(.microphone, MarkerMeeting.microphone),
          ScriptedInput(.system, MarkerMeeting.system),
        ]
      }, checkPermission: {})
    try await recorder.start()
    var sizes: [UInt64] = []
    while true {
      try await Task.sleep(for: .milliseconds(250))
      let current = [CaptureSource.system, .microphone].map {
        (try? FileManager.default.attributesOfItem(
          atPath: CaptureTrack.url(for: $0, in: directory).path)[.size] as? UInt64) ?? 0
      }
      if current == sizes, !current.contains(0) { break }
      sizes = current
    }
    try Data().write(to: ready)
    while true { try await Task.sleep(for: .seconds(60)) }
  }

  static func testCaptureRecovery(root: URL) async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try testADTSFraming()
    try testAbandonedTracks(root: root)
    try testTruncatedTracks(root: root)
    try await testKilledRecorder(root: root)
  }

  private static func testADTSFraming() throws {
    let frames = [12, 300, 768].map {
      ADTS.header(payloadSize: $0) + [UInt8](repeating: 7, count: $0)
    }
    let stream = Data(frames.joined())
    precondition(ADTS.completeLength(of: stream) == stream.count)
    precondition(ADTS.completeLength(of: Data()) == 0)
    for cut in 0..<stream.count {
      let expected = [0, 19, 326, stream.count].last { $0 <= cut }!
      precondition(ADTS.completeLength(of: stream.prefix(cut)) == expected)
    }
    precondition(
      ADTS.completeLength(of: stream.prefix(326) + Data(repeating: 0, count: 900)) == 326)
    var foreign = stream
    foreign[19 + 2] = 0x50
    precondition(ADTS.completeLength(of: foreign) == 19)
  }

  private static func writeMeeting(to directory: URL, finish: Bool) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(MarkerMeeting.manifest).write(
      to: directory.appendingPathComponent("capture.json"))
    for (source, start, chunks) in [
      (CaptureSource.system, MarkerMeeting.systemStart, MarkerMeeting.system),
      (.microphone, MarkerMeeting.microphoneStart, MarkerMeeting.microphone),
    ] {
      let track = try CaptureTrack(url: CaptureTrack.url(for: source, in: directory), start: start)
      for (buffer, time) in chunks { try track.append(buffer, timestamp: time, muted: false) }
      if finish { try track.finish() }
    }
  }

  /// Tracks a killed process leaves behind: written frames without the encoder's final flush.
  private static func testAbandonedTracks(root: URL) throws {
    let directory = root.appendingPathComponent("abandoned")
    try writeMeeting(to: directory, finish: false)
    let mixed = try mixSamples(directory, root.appendingPathComponent("abandoned.m4a"))
    precondition(abs(Double(mixed.count) / 48_000 - 20.75) < 0.15)
    try checkMarkers(mixed, systemLength: 20, microphoneLength: 20)
    print("Tracks abandoned without closing recover with both tracks aligned: OK")
  }

  /// Cuts tracks at arbitrary byte offsets, with and without trailing junk, as a crash or power
  /// loss can leave them.
  private static func testTruncatedTracks(root: URL) throws {
    let complete = root.appendingPathComponent("complete")
    try writeMeeting(to: complete, finish: true)
    let names = ["system.aac", "microphone.aac"]
    let reference = try names.map { try trackSamples(complete.appendingPathComponent($0)) }
    let full = try names.map { try Data(contentsOf: complete.appendingPathComponent($0)) }
    var generator = SplitMix(seed: 0x6d65_6574)
    var cuts = [(0, 0), (3, 7), (full[0].count, 200)]
    for _ in 0..<12 {
      cuts.append(
        (
          Int(generator.next() % UInt64(full[0].count)),
          Int(generator.next() % UInt64(full[1].count))
        ))
    }
    for (index, cut) in cuts.enumerated() {
      let directory = root.appendingPathComponent("cut-\(index)")
      try FileManager.default.copyItem(at: complete, to: directory)
      var lengths: [Double] = []
      for (track, offset) in [cut.0, cut.1].enumerated() {
        let url = directory.appendingPathComponent(names[track])
        var data = full[track].prefix(offset)
        switch index % 3 {
        case 1: data += Data(repeating: 0, count: 4_096)
        case 2: data += Data((0..<4_096).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
        default: break
        }
        try data.write(to: url)
        guard let recovered = try RecoveredTrack(url: url) else {
          precondition(offset < 4_000, "Recovery lost a whole track")
          lengths.append(0)
          continue
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let kept = try Data(contentsOf: url)
        precondition(ADTS.completeLength(of: kept) == size)
        precondition(size <= data.count)
        let samples = try trackSamples(url)
        precondition(samples.count == Int(recovered.length))
        // Decoded prefixes match the finished track sample for sample, so timing is exact.
        let stable = max(0, samples.count - 2_048)
        for sample in stride(from: 0, to: stable, by: 7)
        where abs(samples[sample] - reference[track][sample]) > 1e-4 {
          preconditionFailure("Recovered audio differs at frame \(sample)")
        }
        lengths.append(Double(recovered.length) / 48_000)
      }
      let output = root.appendingPathComponent("cut-\(index).m4a")
      if lengths.allSatisfy({ $0 == 0 }) {
        do {
          try NativeRecorder.mix(directory: directory, destination: output)
          preconditionFailure("Empty tracks must not produce a recording")
        } catch {
          precondition(error.localizedDescription == "No audio was captured.")
        }
        continue
      }
      let mixed = try mixSamples(directory, output)
      let origin = lengths[0] > 0 ? 0 : 0.75
      let expected = max(lengths[0], lengths[1] > 0 ? lengths[1] + 0.75 : 0) - origin
      precondition(abs(Double(mixed.count) / 48_000 - expected) < 0.03)
      try checkMarkers(
        mixed, systemLength: lengths[0], microphoneLength: lengths[1], origin: origin)
    }
    print("Tracks cut at \(cuts.count) byte offsets recover exactly up to the last frame: OK")
  }

  private static func testKilledRecorder(root: URL) async throws {
    let directory = root.appendingPathComponent("killed")
    let ready = root.appendingPathComponent("killed.ready")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [captureUntilKilledFlag, directory.path, ready.path]
    try child.run()
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: ready.path) {
      precondition(child.isRunning && Date() < deadline, "Recording child did not get ready")
      try await Task.sleep(for: .milliseconds(100))
    }
    precondition(kill(child.processIdentifier, SIGKILL) == 0)
    child.waitUntilExit()
    precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
    let mixed = try mixSamples(directory, root.appendingPathComponent("killed.m4a"))
    precondition(abs(Double(mixed.count) / 48_000 - 20.75) < 0.15)
    try checkMarkers(mixed, systemLength: 20, microphoneLength: 20)
    print("SIGKILL during recording: Retry recovers both tracks up to the kill, aligned: OK")
  }

  private static func mixSamples(_ directory: URL, _ output: URL) throws -> [Float] {
    try NativeRecorder.mix(directory: directory, destination: output)
    let file = try AVAudioFile(forReading: output)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  static func trackSamples(_ url: URL) throws -> [Float] {
    guard let track = try RecoveredTrack(url: url) else { return [] }
    guard let buffer = track.read(from: 0, count: AVAudioFrameCount(track.length)) else {
      throw MeetingError("Cannot read \(url.lastPathComponent)")
    }
    return Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  /// Every burst that lies well inside a recovered track appears at its scheduled time, and no
  /// burst appears anywhere else.
  private static func checkMarkers(
    _ samples: [Float], systemLength: Double, microphoneLength: Double, origin: Double = 0
  ) throws {
    var onsets: [Double] = []
    var quietSince = 0
    for (index, sample) in samples.enumerated() where abs(sample) > 0.25 {
      if index - quietSince > 14_400 { onsets.append(Double(index) / 48_000 + origin) }
      quietSince = index
    }
    let scheduled =
      MarkerMeeting.systemMarkers.map { ($0 - MarkerMeeting.systemStart, systemLength) }
      + MarkerMeeting.microphoneMarkers.map {
        (
          $0 - MarkerMeeting.systemStart,
          MarkerMeeting.microphoneStart - MarkerMeeting.systemStart + microphoneLength
        )
      }
    for (time, end) in scheduled where time + MarkerMeeting.burst < end - 0.03 {
      guard onsets.contains(where: { abs($0 - time) < 0.001 }) else {
        throw MeetingError("Missing burst at \(time) s; found \(onsets)")
      }
    }
    for onset in onsets where !scheduled.contains(where: { abs($0.0 - onset) < 0.001 }) {
      throw MeetingError("Unexpected burst at \(onset) s")
    }
  }
}

private struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

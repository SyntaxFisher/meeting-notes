import AVFoundation
import AppKit

struct CaptureManifest: Codable {
  var systemStart: Double?
  var microphoneStart: Double?
}

final class NativeRecorder: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.capture")
  private let lifecycle = DispatchQueue(label: "com.jona.meeting-notes.capture-lifecycle")
  private var inputs: [any AudioCaptureInput] = []
  private var tracks: [CaptureSource: CaptureTrack] = [:]
  private var microphoneMuted = false
  private var acceptingSamples = false
  private var started = false
  private var failure: Error?
  private var manifest = CaptureManifest()
  private let directory: URL
  private let makeInputs: () -> [any AudioCaptureInput]
  private let checkPermission: () throws -> Void
  var onFailure: (@Sendable (Error) -> Void)?

  init(
    directory: URL,
    makeInputs: @escaping () -> [any AudioCaptureInput] = {
      NativeRecorder.captureInputs(
        teamsRunning: !NSRunningApplication.runningApplications(
          withBundleIdentifier: TeamsAudioCapture.bundleID
        ).isEmpty)
    },
    checkPermission: @escaping () throws -> Void = {
      guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        throw PermissionRequired(permission: .microphone)
      }
    }
  ) {
    self.directory = directory
    self.makeInputs = makeInputs
    self.checkPermission = checkPermission
  }

  static func captureInputs(teamsRunning: Bool) -> [any AudioCaptureInput] {
    if teamsRunning { return [TeamsAudioCapture(), MicrophoneCapture()] }
    return [MicrophoneCapture()]
  }

  func setMicrophoneMuted(_ muted: Bool) {
    queue.async { self.microphoneMuted = muted }
  }

  func start() async throws {
    try Task.checkCancellation()
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lifecycle.async { [self] in
          do {
            guard !self.started else { throw MeetingError("This recorder has already started.") }
            self.started = true
            try self.checkPermission()
            let manager = FileManager.default
            if manager.fileExists(atPath: self.directory.path),
              !(try manager.contentsOfDirectory(atPath: self.directory.path)).isEmpty
            {
              throw MeetingError("The capture directory is not empty. Nothing was overwritten.")
            }
            try manager.createDirectory(at: self.directory, withIntermediateDirectories: true)
            self.queue.sync { self.acceptingSamples = true }
            for input in self.makeInputs() {
              self.inputs.append(input)
              let source = input.source
              try input.start(
                receive: { [weak self] buffer, hostTime in
                  self?.queue.async { [weak self] in
                    self?.receive(buffer.buffer, hostTime: hostTime, source: source)
                  }
                },
                onFailure: { [weak self] error in
                  self?.queue.async { [weak self] in self?.recordFailure(error) }
                })
            }
            if let error = self.queue.sync(execute: { self.failure }) { throw error }
            let includesTeams = self.inputs.contains { $0.source == .system }
            AppLog.event(
              "capture.started",
              "\(self.directory.path); mode=\(includesTeams ? "microphone-and-teams" : "microphone-only")"
            )
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
      try Task.checkCancellation()
    } catch {
      try? await stop()
      throw error
    }
  }

  func stop() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lifecycle.async { [self] in
        var stopError: Error?
        for input in self.inputs.reversed() {
          do { try input.stop() } catch { stopError = stopError ?? error }
        }
        self.inputs.removeAll()
        let failure = self.queue.sync {
          self.acceptingSamples = false
          self.tracks.removeAll()
          return self.failure
        }
        if let error = failure ?? stopError {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func recordFailure(_ error: Error) {
    guard acceptingSamples, failure == nil else { return }
    failure = error
    AppLog.event("capture.failed", error.localizedDescription)
    onFailure?(error)
  }

  private func receive(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, source: CaptureSource) {
    guard acceptingSamples, buffer.frameLength > 0, failure == nil else { return }
    do {
      let timestamp = AVAudioTime.seconds(forHostTime: hostTime)
      guard timestamp.isFinite else { throw MeetingError("Captured audio has no valid timestamp.") }
      if tracks[source] == nil {
        tracks[source] = try CaptureTrack(
          url: directory.appendingPathComponent(source.rawValue + ".caf"), start: timestamp)
        switch source {
        case .system: manifest.systemStart = timestamp
        case .microphone: manifest.microphoneStart = timestamp
        }
        try JSONEncoder().encode(manifest).write(
          to: directory.appendingPathComponent("capture.json"), options: .atomic)
        AppLog.event(
          "capture.track",
          "\(source.rawValue); rate=\(buffer.format.sampleRate); channels=\(buffer.format.channelCount)"
        )
      }
      try tracks[source]?.append(
        buffer, timestamp: timestamp, muted: source == .microphone && microphoneMuted)
    } catch { recordFailure(error) }
  }

  static func mix(directory: URL, destination: URL) throws {
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("capture.json"))
    )
    // Both tracks use timestamps from the same host clock.
    let sources = [("system", manifest.systemStart), ("microphone", manifest.microphoneStart)]
    guard let origin = sources.compactMap({ $0.1 }).min() else {
      throw MeetingError("No audio was captured.")
    }
    var inputs: [(AVAudioFile, AVAudioFramePosition)] = []
    for (name, timestamp) in sources {
      guard let timestamp else { continue }
      let file = try AVAudioFile(forReading: directory.appendingPathComponent(name + ".caf"))
      guard file.processingFormat.sampleRate == 48_000, file.processingFormat.channelCount == 1
      else {
        throw MeetingError("Unexpected captured audio format.")
      }
      inputs.append((file, AVAudioFramePosition(max(0, timestamp - origin) * 48_000)))
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw MeetingError("The recording already exists. Nothing was overwritten.")
    }
    let end = inputs.map { $0.0.length + $0.1 }.max() ?? 0
    guard end > 0 else { throw MeetingError("No audio was captured.") }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let writer = try AVAudioFile(
      forWriting: destination,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
      ])
    var position: AVAudioFramePosition = 0
    while position < end {
      try Task.checkCancellation()
      let count = AVAudioFrameCount(min(32_768, end - position))
      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
      output.frameLength = count
      let samples = output.floatChannelData![0]
      samples.initialize(repeating: 0, count: Int(count))
      for (input, offset) in inputs {
        let start = max(position, offset)
        let stop = min(position + Int64(count), offset + input.length)
        guard stop > start else { continue }
        input.framePosition = start - offset
        let buffer = AVAudioPCMBuffer(
          pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(stop - start))!
        try input.read(into: buffer)
        for i in 0..<Int(buffer.frameLength) {
          samples[Int(start - position) + i] += buffer.floatChannelData![0][i]
        }
      }
      for i in 0..<Int(count) { samples[i] = max(-1, min(1, samples[i])) }
      try writer.write(from: output)
      position += Int64(count)
    }
  }
}

final class CaptureTrack {
  private let file: AVAudioFile
  private let start: Double
  private var written: Int64 = 0
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
  private var converter: AVAudioConverter?

  init(url: URL, start: Double) throws {
    self.start = start
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw MeetingError("The audio track already exists. Nothing was overwritten.")
    }
    file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
      ])
  }

  func append(_ input: AVAudioPCMBuffer, timestamp: Double, muted: Bool) throws {
    if converter == nil || converter!.inputFormat != input.format {
      converter = AVAudioConverter(from: input.format, to: format)
    }
    guard let converter else { throw MeetingError("Cannot convert captured audio.") }
    let capacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate) + 32)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: buffer, error: &error) { _, result in
      if supplied {
        result.pointee = .noDataNow
        return nil
      }
      supplied = true
      result.pointee = .haveData
      return input
    }
    if let error { throw error }
    guard status != .error else { throw MeetingError("Audio conversion failed.") }
    let expected = Int64(max(0, timestamp - start) * 48_000)
    // Fill genuine capture gaps; ignore sub-buffer timestamp rounding.
    if expected - written > 2_400 {
      var gap = expected - written
      while gap > 0 {
        let count = AVAudioFrameCount(min(gap, 32_768))
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        silence.frameLength = count
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(count))
        try file.write(from: silence)
        written += Int64(count)
        gap -= Int64(count)
      }
    }
    if muted {
      buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    }
    try file.write(from: buffer)
    written += Int64(buffer.frameLength)
  }
}

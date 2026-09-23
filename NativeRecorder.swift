import AVFoundation
import ScreenCaptureKit

struct CaptureManifest: Codable {
  var systemStart: Double?
  var microphoneStart: Double?
}

final class NativeRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.capture")
  private var stream: SCStream?
  private var tracks: [SCStreamOutputType: CaptureTrack] = [:]
  private var microphoneMuted = false
  private var failure: Error?
  private var manifest = CaptureManifest()
  private let directory: URL
  var onFailure: (@Sendable (Error) -> Void)?

  init(directory: URL) { self.directory = directory }

  func setMicrophoneMuted(_ muted: Bool) {
    queue.async { self.microphoneMuted = muted }
  }

  func start() async throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw PermissionRequired(permission: .microphone)
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      throw MeetingError("No display is available for system audio capture.")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let teams = content.applications.filter { $0.bundleIdentifier == "com.microsoft.teams2" }
    let configuration = Self.configuration(teamsApplicationCount: teams.count)
    let filter = SCContentFilter(display: display, including: teams, exceptingWindows: [])
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    if configuration.capturesAudio {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    }
    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
    self.stream = stream
    try await stream.startCapture()
    if let error = queue.sync(execute: { failure }) { throw error }
    AppLog.event(
      "capture.started",
      "\(directory.path); mode=\(teams.isEmpty ? "microphone-only" : "microphone-and-teams")")
  }

  static func configuration(teamsApplicationCount: Int) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = teamsApplicationCount > 0
    configuration.captureMicrophone = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 1
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
    configuration.showsCursor = false
    return configuration
  }

  func stop() async throws {
    var stopError: Error?
    if let stream {
      do { try await stream.stopCapture() } catch { stopError = error }
    }
    stream = nil
    await withCheckedContinuation { continuation in
      queue.async {
        self.tracks.removeAll()
        continuation.resume()
      }
    }
    if let failure { throw failure }
    if let stopError { throw stopError }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    queue.async { self.recordFailure(error) }
  }

  private func recordFailure(_ error: Error) {
    guard failure == nil else { return }
    failure = error
    AppLog.event("capture.failed", error.localizedDescription)
    onFailure?(error)
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio || type == .microphone, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
      failure == nil
    else { return }
    do {
      guard let description = sampleBuffer.formatDescription else {
        throw MeetingError("Captured audio has no format.")
      }
      let format = AVAudioFormat(cmAudioFormatDescription: description)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
      else { throw MeetingError("Cannot read captured audio format.") }
      buffer.frameLength = buffer.frameCapacity
      let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength),
        into: buffer.mutableAudioBufferList)
      guard status == noErr else { throw MeetingError("Cannot copy captured audio (\(status)).") }
      let timestamp = sampleBuffer.presentationTimeStamp.seconds
      guard timestamp.isFinite else { throw MeetingError("Captured audio has no valid timestamp.") }
      if tracks[type] == nil {
        let name = type == .audio ? "system" : "microphone"
        tracks[type] = try CaptureTrack(
          url: directory.appendingPathComponent(name + ".caf"), start: timestamp)
        if type == .audio {
          manifest.systemStart = timestamp
        } else {
          manifest.microphoneStart = timestamp
        }
        try JSONEncoder().encode(manifest).write(
          to: directory.appendingPathComponent("capture.json"), options: .atomic)
        AppLog.event(
          "capture.track", "\(name); rate=\(format.sampleRate); channels=\(format.channelCount)")
      }
      try tracks[type]?.append(
        buffer, timestamp: timestamp, muted: type == .microphone && microphoneMuted)
    } catch { recordFailure(error) }
  }

  static func mix(directory: URL, destination: URL) throws {
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("capture.json"))
    )
    // Both streams use presentation timestamps from the same host clock.
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

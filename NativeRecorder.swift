import AVFoundation

/// `capture.json`: the start of each track on the host clock, whose playback the system
/// track holds, and when the microphone was muted. A mute without an end lasted until the
/// recording stopped; the microphone track holds silence for every mute.
struct CaptureManifest: Codable {
  struct Mute: Codable, Equatable {
    var start: Double
    var end: Double?
  }

  var systemStart: Double?
  var microphoneStart: Double?
  var systemAudio: SystemAudioScope?
  var microphoneMutes: [Mute]?
  /// Each track's input format before encoding, such as "48000 Hz, 2 ch", by source.
  var inputFormats: [String: String]?
}

final class NativeRecorder: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.capture")
  private let lifecycle = DispatchQueue(label: "com.jona.meeting-notes.capture-lifecycle")
  private var inputs: [any AudioCaptureInput] = []
  private var expectedSources: [CaptureSource] = []
  private var tracks: [CaptureSource: CaptureTrack] = [:]
  private var microphoneMuted = false
  private var acceptingSamples = false
  private var started = false
  private var failure: Error?
  private var manifest = CaptureManifest()
  private let directory: URL
  private let systemAudio: SystemAudioScope?
  private let makeInputs: () -> [any AudioCaptureInput]
  private let checkPermission: () throws -> Void
  var onFailure: (@Sendable (Error) -> Void)?

  /// Records the microphone and the system audio of `systemAudio`, or the microphone alone.
  convenience init(directory: URL, systemAudio: SystemAudioScope?) {
    self.init(
      directory: directory, systemAudio: systemAudio,
      makeInputs: { NativeRecorder.captureInputs(systemAudio: systemAudio) })
  }

  /// `systemAudio` describes the `.system` input among `makeInputs`, if there is one.
  init(
    directory: URL,
    systemAudio: SystemAudioScope? = nil,
    makeInputs: @escaping () -> [any AudioCaptureInput],
    checkPermission: @escaping () throws -> Void = {
      guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        throw PermissionRequired(permission: .microphone)
      }
    }
  ) {
    self.directory = directory
    self.systemAudio = systemAudio
    self.makeInputs = makeInputs
    self.checkPermission = checkPermission
  }

  static func captureInputs(systemAudio: SystemAudioScope?) -> [any AudioCaptureInput] {
    // Opening a Bluetooth microphone can change the output device's format too.
    guard let systemAudio else { return [MicrophoneCapture()] }
    return [MicrophoneCapture(), SystemAudioCapture(scope: systemAudio)]
  }

  /// What the running recording captures.
  var meetingSource: MeetingSource {
    queue.sync { expectedSources.contains(.system) ? MeetingSource(systemAudio) : .microphone }
  }

  func setMicrophoneMuted(_ muted: Bool) {
    let time = AVAudioTime.seconds(forHostTime: mach_absolute_time())
    queue.async {
      guard muted != self.microphoneMuted else { return }
      self.microphoneMuted = muted
      var mutes = self.manifest.microphoneMutes ?? []
      if muted {
        mutes.append(.init(start: time))
      } else if let last = mutes.indices.last, mutes[last].end == nil {
        mutes[last].end = time
      }
      self.manifest.microphoneMutes = mutes
      if !self.tracks.isEmpty { self.writeManifest() }
    }
  }

  private func writeManifest() {
    do {
      try JSONEncoder().encode(manifest).write(
        to: directory.appendingPathComponent("capture.json"), options: .atomic)
    } catch { AppLog.event("capture.manifestFailed", error.localizedDescription) }
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
            let inputs = self.makeInputs()
            self.queue.sync {
              self.expectedSources = inputs.map(\.source)
              if self.expectedSources.contains(.system) {
                self.manifest.systemAudio = self.systemAudio
              }
            }
            for input in inputs {
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
            let system = self.inputs.contains { $0.source == .system }
            let mode =
              system ? self.systemAudio?.mode ?? "microphone-and-system" : "microphone-only"
            AppLog.event("capture.started", "\(self.directory.path); mode=\(mode)")
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
          var finishError: Error?
          for source in self.expectedSources {
            do { try self.tracks[source]?.finish() } catch { finishError = finishError ?? error }
            AppLog.event(
              "capture.summary",
              "\(source.rawValue); \(self.tracks[source]?.summary ?? "buffers=0; frames=0")")
          }
          self.expectedSources.removeAll()
          self.tracks.removeAll()
          return self.failure ?? finishError
        }
        if let error = failure ?? stopError {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func discard() async throws {
    do { try await stop() } catch {
      AppLog.event("capture.discardStopFailed", error.localizedDescription)
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    AppLog.event("capture.discarded", directory.path)
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
        switch source {
        case .system: manifest.systemStart = timestamp
        case .microphone: manifest.microphoneStart = timestamp
        }
        manifest.inputFormats = (manifest.inputFormats ?? [:]).merging([
          source.rawValue:
            "\(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch"
        ]) { $1 }
        try JSONEncoder().encode(manifest).write(
          to: directory.appendingPathComponent("capture.json"), options: .atomic)
        tracks[source] = try CaptureTrack(
          url: CaptureTrack.url(for: source, in: directory), start: timestamp)
        AppLog.event(
          "capture.track",
          "\(source.rawValue); rate=\(buffer.format.sampleRate); channels=\(buffer.format.channelCount)"
        )
      }
      try tracks[source]?.append(
        buffer, timestamp: timestamp, muted: source == .microphone && microphoneMuted)
    } catch { recordFailure(error) }
  }

  /// Mixes whatever the capture directory holds, including tracks of a recording that never
  /// stopped: each track is recovered up to its last complete frame.
  static func mix(directory: URL, destination: URL) throws {
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("capture.json"))
    )
    var tracks: [(RecoveredTrack, Double)] = []
    for (source, start) in [
      (CaptureSource.system, manifest.systemStart), (.microphone, manifest.microphoneStart),
    ] {
      guard let start,
        let track = try RecoveredTrack(url: CaptureTrack.url(for: source, in: directory))
      else { continue }
      tracks.append((track, start))
    }
    // Both tracks use timestamps from the same host clock.
    guard let origin = tracks.map(\.1).min() else { throw MeetingError("No audio was captured.") }
    let inputs = tracks.map { track, start in
      (track, AVAudioFramePosition(((start - origin) * CaptureTrack.sampleRate).rounded()))
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw MeetingError("The recording already exists. Nothing was overwritten.")
    }
    let end = inputs.map { $0.0.length + $0.1 }.max() ?? 0
    let format = CaptureTrack.format
    let writer = try AVAudioFile(
      forWriting: destination,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: CaptureTrack.sampleRate,
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
        guard let buffer = input.read(from: start - offset, count: AVAudioFrameCount(stop - start))
        else { continue }
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

/// AAC-LC frames with ADTS headers. Every frame carries its own length, so any prefix of a
/// track that ends on a frame boundary decodes on its own: no index or trailer is ever written.
enum ADTS {
  static let headerSize = 7
  /// The AAC encoder prepends this many priming frames; ADTS has no field to record them.
  static let encoderDelay: AVAudioFramePosition = 2_112
  // MPEG-4, no CRC, AAC-LC, 48 kHz, mono.
  private static let fixedHeader: [UInt8] = [0xFF, 0xF1, 0x4C, 0x40]

  static func header(payloadSize: Int) -> [UInt8] {
    let length = payloadSize + headerSize
    precondition(length < 1 << 13)
    return [
      fixedHeader[0], fixedHeader[1], fixedHeader[2], fixedHeader[3] | UInt8(length >> 11),
      UInt8((length >> 3) & 0xFF), UInt8((length & 7) << 5 | 0x1F), 0xFC,
    ]
  }

  /// Byte length of the leading run of complete frames that match the header this app writes.
  static func completeLength(of data: Data) -> Int {
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      var offset = 0
      while offset + headerSize <= bytes.count {
        let header = { (index: Int) in bytes[offset + index] }
        guard header(0) == fixedHeader[0], header(1) == fixedHeader[1],
          header(2) == fixedHeader[2], header(3) & 0xFC == fixedHeader[3],
          header(5) & 0x1F == 0x1F, header(6) == 0xFC
        else { break }
        let length = Int(header(3) & 0x03) << 11 | Int(header(4)) << 3 | Int(header(5)) >> 5
        guard length > headerSize, offset + length <= bytes.count else { break }
        offset += length
      }
      return offset
    }
  }
}

/// Writes one capture source as an ADTS stream with a single write per encoded buffer.
/// A killed process therefore loses only the encoder's look-ahead; periodic full syncs bound
/// what a power loss can take.
final class CaptureTrack {
  static let sampleRate = 48_000.0
  static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
  static let syncInterval = AVAudioFramePosition(5 * sampleRate)

  static func url(for source: CaptureSource, in directory: URL) -> URL {
    directory.appendingPathComponent(source.rawValue + ".aac")
  }

  private let handle: FileHandle
  private let start: Double
  private let encoder: AVAudioConverter
  private var converter: AVAudioConverter?
  private var written: AVAudioFramePosition = 0
  private var synced = -syncInterval
  private var closed = false
  private var statistics = CaptureSignalStatistics()

  var summary: String {
    statistics.summary
  }

  init(url: URL, start: Double) throws {
    self.start = start
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw MeetingError("The audio track already exists. Nothing was overwritten.")
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let aac = AVAudioFormat(settings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
      AVNumberOfChannelsKey: 1,
    ])
    guard let aac, let encoder = AVAudioConverter(from: Self.format, to: aac) else {
      try? handle.close()
      throw MeetingError("Cannot create the audio encoder.")
    }
    encoder.bitRate = 96_000
    self.encoder = encoder
  }

  deinit {
    if !closed { try? handle.close() }
  }

  func append(_ input: AVAudioPCMBuffer, timestamp: Double, muted: Bool) throws {
    guard !closed else { throw MeetingError("The audio track is already finished.") }
    if converter == nil || converter!.inputFormat != input.format {
      converter = AVAudioConverter(from: input.format, to: Self.format)
    }
    guard let converter else { throw MeetingError("Cannot convert captured audio.") }
    let capacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * Self.sampleRate / input.format.sampleRate) + 32)
    let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity)!
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
    let samples = UnsafeBufferPointer(
      start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    statistics.received(frames: Int64(buffer.frameLength), peak: peak, muted: muted)
    let expected = AVAudioFramePosition(max(0, timestamp - start) * Self.sampleRate)
    // Fill genuine capture gaps; ignore sub-buffer timestamp rounding.
    if expected - written > 2_400 {
      var gap = expected - written
      while gap > 0 {
        let count = AVAudioFrameCount(min(gap, 32_768))
        let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: count)!
        silence.frameLength = count
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(count))
        try encode(silence)
        gap -= Int64(count)
      }
    }
    if muted {
      buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    }
    try encode(buffer)
    if written - synced >= Self.syncInterval {
      try synchronize()
      synced = written
    }
  }

  /// Flushes the encoder's look-ahead and closes the track.
  func finish() throws {
    guard !closed else { return }
    defer {
      closed = true
      try? handle.close()
    }
    try encode(nil)
    try synchronize()
  }

  private func encode(_ input: AVAudioPCMBuffer?) throws {
    var supplied = false
    var frames: [UInt8] = []
    var status: AVAudioConverterOutputStatus
    repeat {
      let output = AVAudioCompressedBuffer(
        format: encoder.outputFormat, packetCapacity: 16,
        maximumPacketSize: encoder.maximumOutputPacketSize)
      var error: NSError?
      status = encoder.convert(to: output, error: &error) { _, result in
        guard let input else {
          result.pointee = .endOfStream
          return nil
        }
        if supplied {
          result.pointee = .noDataNow
          return nil
        }
        supplied = true
        result.pointee = .haveData
        return input
      }
      if let error { throw error }
      guard status != .error else { throw MeetingError("Audio encoding failed.") }
      let payload = output.data.assumingMemoryBound(to: UInt8.self)
      for packet in UnsafeBufferPointer(
        start: output.packetDescriptions, count: Int(output.packetCount))
      {
        frames += ADTS.header(payloadSize: Int(packet.mDataByteSize))
        frames += UnsafeBufferPointer(
          start: payload + Int(packet.mStartOffset), count: Int(packet.mDataByteSize))
      }
    } while status == .haveData
    if !frames.isEmpty { try handle.write(contentsOf: frames) }
    written += AVAudioFramePosition(input?.frameLength ?? 0)
  }

  private func synchronize() throws {
    if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
  }
}

/// A capture track opened for mixing, whether or not its recording finished.
final class RecoveredTrack {
  private let file: AVAudioFile
  private(set) var length: AVAudioFramePosition

  /// Cuts an incomplete trailing frame from the track and opens it; nil when it holds no audio.
  init?(url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let (complete, size) = try {
      let data = try Data(contentsOf: url, options: .alwaysMapped)
      return (ADTS.completeLength(of: data), data.count)
    }()
    if complete < size {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.truncate(atOffset: UInt64(complete))
      AppLog.event(
        "capture.recovered",
        "\(url.lastPathComponent); kept=\(complete) bytes; cut=\(size - complete) bytes")
    }
    guard complete > 0 else { return nil }
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      // Only a track whose first frames never reached the disk intact gets here.
      AppLog.event("capture.unreadable", "\(url.lastPathComponent); \(error.localizedDescription)")
      return nil
    }
    guard file.processingFormat.sampleRate == CaptureTrack.sampleRate,
      file.processingFormat.channelCount == 1
    else {
      throw MeetingError("Unexpected captured audio format.")
    }
    length = file.length - ADTS.encoderDelay
    // The reader indexes a frame whose payload never reached the disk but cannot decode it.
    let tail = min(length, 8_192)
    if tail > 0, let buffer = read(from: length - tail, count: AVAudioFrameCount(tail)) {
      length += AVAudioFramePosition(buffer.frameLength) - tail
    }
    guard length > 0 else { return nil }
  }

  /// Reads captured frames; a frame that cannot be decoded ends the track there.
  func read(from position: AVAudioFramePosition, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
    do {
      file.framePosition = position + ADTS.encoderDelay
      try file.read(into: buffer, frameCount: count)
      return buffer
    } catch {
      AppLog.event(
        "capture.trackEnded",
        "\(file.url.lastPathComponent); frame=\(position); \(error.localizedDescription)")
      length = position
      return nil
    }
  }
}

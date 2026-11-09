import AVFoundation
import FluidAudio
import Foundation

struct TranscriptionFailure: LocalizedError {
  let message: String
  var noSpeech = false
  var errorDescription: String? { message }
}

func isNoSpeech(_ error: Error) -> Bool {
  if case OfflineDiarizationError.noSpeechDetected = error { return true }
  return (error as? TranscriptionFailure)?.noSpeech == true
}

/// The app's `capture.json`: start times of each track on the host clock and whose playback
/// the system track holds (`teams`, `device-audio` or `app:<bundle id>`).
private struct CaptureManifest: Decodable {
  var systemStart: Double?
  var microphoneStart: Double?
  var systemAudio: String?
}

/// One audio file whisper transcribes, with the diarized turns its words are attributed to.
private struct Track {
  var file: URL
  var source: TranscriptSegments.Source
  var turns: [SpeechPlan.Turn]
  var policy: SpeechPlan.Policy
  var chunks: [SpeechPlan.Chunk] = []
}

/// Usage: `MeetingTranscriber <audio> <output.json> <progress.json> [<capture directory>]`.
/// With a capture directory that holds both the microphone and the system track (Teams or all
/// device audio), each track is transcribed on its own; otherwise the mixed audio is diarized.
@main
struct Transcriber {
  static let sampleRate = 16_000
  static let engine =
    "whisper large-v3-turbo (whisper.cpp 1.9.5, Silero VAD) with FluidAudio offline diarization"

  static func main() async {
    let args = CommandLine.arguments
    guard args.count == 4 || args.count == 5 else { exit(2) }
    let parent = getppid()
    let watchdog = DispatchSource.makeTimerSource()
    watchdog.schedule(deadline: .now() + 2, repeating: 2)
    // _exit skips static destructors, which must not run while the GPU model is in use.
    watchdog.setEventHandler { @Sendable in if getppid() != parent { _exit(1) } }
    watchdog.resume()
    defer { watchdog.cancel() }
    let input = URL(fileURLWithPath: args[1])
    let output = URL(fileURLWithPath: args[2])
    let progress = URL(fileURLWithPath: args[3])
    let capture = args.count == 5 ? URL(fileURLWithPath: args[4], isDirectory: true) : nil
    let reporter = ProgressReporter(file: progress)
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "meeting-transcriber-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    do {
      guard !FileManager.default.fileExists(atPath: output.path) else {
        throw TranscriptionFailure(message: "Output already exists.")
      }
      try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let vadModel = try await ModelStore.ensure(.silero) { _ in }
      let whisperModel = try await ModelStore.ensure(.whisper) { fraction in
        reporter.report("Downloading the transcription model \(Int(fraction * 100))%")
      }
      let detector = try VoiceActivityDetector(model: vadModel)
      var (tracks, result) = try await diarize(
        input, capture: capture, workspace: workspace, reporter: reporter, detector: detector)
      guard tracks.contains(where: { !$0.turns.isEmpty }) else {
        throw TranscriptionFailure(
          message: "No speech was detected in the recording.", noSpeech: true)
      }
      reporter.report("Preparing whisper large-v3-turbo")
      let recognizer = try WhisperRecognizer(model: whisperModel)
      for index in tracks.indices {
        reporter.report("Finding speech")
        let samples = try samples(of: tracks[index].file)
        let passages = SpeechPlan.passages(
          regions: try detector.regions(in: samples), turns: tracks[index].turns,
          policy: tracks[index].policy, trackDuration: Double(samples.count) / Double(sampleRate))
        reporter.report("Detecting languages")
        let detections = passages.map { passage -> SpeechPlan.Detection? in
          guard passage.end - passage.start >= SpeechPlan.minimumLanguageSeconds else {
            return nil
          }
          return recognizer.language(of: audio(of: passage, in: samples))
        }
        let languages = SpeechPlan.languages(passages: passages, detections: detections)
        tracks[index].chunks = SpeechPlan.chunks(passages: passages, languages: languages)
      }
      let total = tracks.reduce(0) { $0 + $1.chunks.count }
      guard total > 0 else {
        throw TranscriptionFailure(
          message: "No speech was detected in the recording.", noSpeech: true)
      }
      var part = 0
      for track in tracks where !track.chunks.isEmpty {
        let samples = try samples(of: track.file)
        for chunk in track.chunks {
          part += 1
          reporter.report("Transcribing part \(part)/\(total)")
          let words = chunk.place(
            try recognizer.words(in: audio(of: chunk, in: samples), language: chunk.language))
          result.segments += SpeechPlan.segments(
            words: words, turns: track.turns, policy: track.policy
          ).map {
            .init(
              start: $0.start, end: $0.end, source: track.source, speaker: $0.speaker,
              text: $0.text)
          }
        }
      }
      result.segments = merged(result.segments.sorted { $0.start < $1.start })
      guard !result.segments.isEmpty else {
        throw TranscriptionFailure(
          message: "No speech was recognized in the recording.", noSpeech: true)
      }
      reporter.speakerCount =
        Set(result.segments.map { "\($0.source.rawValue) \($0.speaker)" })
        .count
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(result).write(to: output, options: .withoutOverwriting)
      reporter.report("Complete")
    } catch {
      reporter.report("Failed", error: error.localizedDescription, noSpeech: isNoSpeech(error))
      _exit(1)
    }
  }

  /// Finds who speaks when. The diarizer is released before whisper loads.
  private static func diarize(
    _ input: URL, capture: URL?, workspace: URL, reporter: ProgressReporter,
    detector: VoiceActivityDetector
  ) async throws -> ([Track], TranscriptSegments) {
    reporter.report("Preparing speaker models")
    let diarizer = OfflineDiarizerManager(config: .default)
    try await diarizer.prepareModels()
    let tracks = try capture.flatMap { try separateTracks(in: $0, workspace: workspace) }
    var remote: [SpeechPlan.Turn] = []
    if let system = tracks?.system {
      reporter.report("Identifying remote speakers")
      remote = try await diarize(system, with: diarizer, detector: detector)
    }
    guard let tracks else {
      reporter.report("Identifying speakers")
      let turns = try await diarize(input, with: diarizer, detector: detector)
      let audio = try AVAudioFile(forReading: input)
      return (
        [Track(file: input, source: .mix, turns: turns, policy: .speakers)],
        TranscriptSegments(
          mode: .mixed, duration: Double(audio.length) / audio.processingFormat.sampleRate,
          segments: [], engine: engine)
      )
    }
    reporter.report("Finding your speech")
    let local = try detector.regions(in: samples(of: tracks.microphone))
    let echo = EchoFilter(microphone: tracks.microphoneLoudness, teams: tracks.systemLoudness)
    // Development switch for measuring the filter's effect.
    let filtering = ProcessInfo.processInfo.environment["MEETING_NOTES_ECHO_FILTER"] != "off"
    let ranges = local.flatMap {
      let start = Double($0.start)
      let end = Double($0.end)
      return filtering ? echo.localRanges(start: start, end: end) : [start...end]
    }
    let localSeconds = local.reduce(0.0) { $0 + ($1.end - $1.start) }
    let keptSeconds = ranges.reduce(0.0) { $0 + $1.upperBound - $1.lowerBound }
    return (
      [
        Track(
          file: tracks.microphone, source: .microphone,
          turns: ranges.map { .init(start: $0.lowerBound, end: $0.upperBound, speaker: "local") },
          policy: .localSpeech),
        Track(
          file: tracks.system, source: tracks.systemSource, turns: remote,
          policy: .speakers),
      ],
      TranscriptSegments(
        mode: .separateTracks, duration: tracks.duration, segments: [],
        echo: .init(
          lagSeconds: Double(echo.lagFrames) * EchoFilter.frameSeconds,
          coupling: Double(echo.coupling),
          discardedSeconds: (max(0, localSeconds - keptSeconds) * 10).rounded() / 10),
        engine: engine)
    )
  }

  private static func turns(of segments: [TimedSpeakerSegment]) -> [SpeechPlan.Turn] {
    let segmentation = OfflineDiarizerConfig.default.segmentation
    return SpeechPlan.repairedTurns(
      segments.map {
        SpeechPlan.Turn(
          start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
          speaker: $0.speakerId)
      }, windowStep: segmentation.windowDurationSeconds * segmentation.stepRatio)
  }

  /// Consecutive segments of the same speaker with short pauses become one turn.
  private static func merged(_ segments: [TranscriptSegments.Segment])
    -> [TranscriptSegments.Segment]
  {
    var result: [TranscriptSegments.Segment] = []
    for segment in segments {
      if var last = result.last, last.source == segment.source, last.speaker == segment.speaker,
        segment.start - last.end < 1.0, segment.end - last.start < 60
      {
        last.end = max(last.end, segment.end)
        last.text += " " + segment.text
        result[result.count - 1] = last
      } else {
        result.append(segment)
      }
    }
    return result
  }

  private static func diarize(
    _ file: URL, with diarizer: OfflineDiarizerManager, detector: VoiceActivityDetector
  ) async throws -> [SpeechPlan.Turn] {
    let diarized: [SpeechPlan.Turn]
    do {
      diarized = turns(of: try await diarizer.process(file).segments)
    } catch {
      guard isNoSpeech(error) else { throw error }
      diarized = []
    }
    guard diarized.isEmpty else { return diarized }
    return SpeechPlan.unidentifiedTurns(in: try detector.regions(in: samples(of: file)))
  }

  /// The audio of one passage.
  private static func audio(of passage: SpeechPlan.Passage, in samples: [Float]) -> [Float] {
    let rate = Double(sampleRate)
    let range = max(0, Int(passage.start * rate))..<min(samples.count, Int(passage.end * rate))
    return range.isEmpty ? [] : Array(samples[range])
  }

  /// The audio whisper hears for a chunk: its passages at their offsets, with the recorded
  /// audio in kept pauses and silence in joined ones, padded to whisper's one-second minimum.
  private static func audio(of chunk: SpeechPlan.Chunk, in samples: [Float]) -> [Float] {
    let rate = Double(sampleRate)
    var audio = [Float](repeating: 0, count: max(Int(chunk.duration * rate), Int(1.2 * rate)))
    func copy(from start: Double, to end: Double, at offset: Double) {
      let source = max(0, Int(start * rate))..<min(samples.count, Int(end * rate))
      guard !source.isEmpty else { return }
      for (index, sample) in zip(Int(offset * rate)..<audio.count, samples[source]) {
        audio[index] = sample
      }
    }
    var previous: SpeechPlan.Piece?
    for piece in chunk.pieces {
      if let previous,
        abs((piece.offset - previous.endOffset) - (piece.passage.start - previous.passage.end))
          < 0.001
      {
        copy(from: previous.passage.end, to: piece.passage.start, at: previous.endOffset)
      }
      copy(from: piece.passage.start, to: piece.passage.end, at: piece.offset)
      previous = piece
    }
    return audio
  }

  /// Reads any audio file as 16 kHz mono samples.
  private static func samples(of file: URL) throws -> [Float] {
    let input = try AVAudioFile(forReading: file)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
      interleaved: false)!
    guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
      throw TranscriptionFailure(message: "Unsupported audio format.")
    }
    var samples: [Float] = []
    samples.reserveCapacity(
      Int(Double(input.length) * Double(sampleRate) / input.processingFormat.sampleRate) + 1)
    let chunk: AVAudioFrameCount = 64_000
    while true {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
      var error: NSError?
      let status = converter.convert(to: buffer, error: &error) { _, state in
        let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk * 3)!
        do { try input.read(into: read) } catch {
          state.pointee = .endOfStream
          return nil
        }
        guard read.frameLength > 0 else {
          state.pointee = .endOfStream
          return nil
        }
        state.pointee = .haveData
        return read
      }
      if let error { throw error }
      samples.append(
        contentsOf: UnsafeBufferPointer(
          start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      if status == .endOfStream || status == .error { break }
    }
    return samples
  }

  private struct Tracks {
    let microphone: URL
    let system: URL
    let systemSource: TranscriptSegments.Source
    let microphoneLoudness: [Float]
    let systemLoudness: [Float]
    let duration: Double
  }

  /// Converts both capture tracks to 16 kHz files on the mixed recording's timeline.
  private static func separateTracks(in capture: URL, workspace: URL) throws -> Tracks? {
    let manifestURL = capture.appendingPathComponent("capture.json")
    guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(CaptureManifest.self, from: data),
      let systemStart = manifest.systemStart, let microphoneStart = manifest.microphoneStart
    else { return nil }
    let origin = min(systemStart, microphoneStart)
    let microphone = workspace.appendingPathComponent("microphone.wav")
    let system = workspace.appendingPathComponent("system.wav")
    let microphoneLoudness = try align(
      capture.appendingPathComponent("microphone.aac"), offset: microphoneStart - origin,
      to: microphone)
    let systemLoudness = try align(
      capture.appendingPathComponent("system.aac"), offset: systemStart - origin, to: system)
    let frames = max(microphoneLoudness.count, systemLoudness.count)
    return Tracks(
      microphone: microphone, system: system,
      systemSource: TranscriptSegments.Source(systemAudio: manifest.systemAudio),
      microphoneLoudness: microphoneLoudness, systemLoudness: systemLoudness,
      duration: Double(frames) * EchoFilter.frameSeconds)
  }

  /// The AAC encoder's priming frames at the start of every capture track, which ADTS cannot
  /// record; the app skips the same number when it mixes the tracks.
  static let encoderDelay: AVAudioFramePosition = 2_112

  /// Writes `source` as 16 kHz mono after `offset` seconds of silence and returns its loudness
  /// per `EchoFilter.frameSeconds` frame. Reading stops at the first frame that cannot be
  /// decoded, which only the end of a recovered track can contain.
  private static func align(_ source: URL, offset: Double, to destination: URL) throws -> [Float] {
    let input = try AVAudioFile(forReading: source)
    input.framePosition = min(encoderDelay, input.length)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
      interleaved: false)!
    let output = try AVAudioFile(
      forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
      throw TranscriptionFailure(message: "Unsupported captured audio format.")
    }
    let frameLength = Int(EchoFilter.frameSeconds * Double(sampleRate))
    var loudness: [Float] = []
    var pending: [Float] = []
    func write(_ buffer: AVAudioPCMBuffer) throws {
      guard buffer.frameLength > 0 else { return }
      try output.write(from: buffer)
      pending.append(
        contentsOf: UnsafeBufferPointer(
          start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      var index = 0
      while pending.count - index >= frameLength {
        var sum: Float = 0
        for sample in pending[index..<index + frameLength] { sum += sample * sample }
        loudness.append((sum / Float(frameLength)).squareRoot())
        index += frameLength
      }
      pending.removeFirst(index)
    }
    var silence = Int(max(0, offset) * Double(sampleRate))
    while silence > 0 {
      let count = min(silence, 160_000)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
      buffer.frameLength = AVAudioFrameCount(count)
      buffer.floatChannelData![0].initialize(repeating: 0, count: count)
      try write(buffer)
      silence -= count
    }
    let chunk: AVAudioFrameCount = 48_000
    var finished = false
    while !finished {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
      var error: NSError?
      let status = converter.convert(to: buffer, error: &error) { _, state in
        let read = AVAudioPCMBuffer(
          pcmFormat: input.processingFormat, frameCapacity: chunk * 3)!
        do { try input.read(into: read) } catch {
          state.pointee = .endOfStream
          return nil
        }
        guard read.frameLength > 0 else {
          state.pointee = .endOfStream
          return nil
        }
        state.pointee = .haveData
        return read
      }
      if let error { throw error }
      try write(buffer)
      finished = status == .endOfStream || status == .error
    }
    return loudness
  }
}

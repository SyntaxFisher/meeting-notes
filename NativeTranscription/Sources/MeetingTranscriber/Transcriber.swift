import AVFoundation
import FluidAudio
import Foundation

struct TranscriptionFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@main
struct Transcriber {
  static func main() async {
    let args = CommandLine.arguments
    guard args.count == 4 else { exit(2) }
    let parent = getppid()
    let watchdog = DispatchSource.makeTimerSource()
    watchdog.schedule(deadline: .now() + 2, repeating: 2)
    watchdog.setEventHandler { @Sendable in if getppid() != parent { exit(1) } }
    watchdog.resume()
    defer { watchdog.cancel() }
    let input = URL(fileURLWithPath: args[1])
    let output = URL(fileURLWithPath: args[2])
    let progress = URL(fileURLWithPath: args[3])
    var speakerCount: Int?
    func report(_ stage: String, error: String? = nil) {
      var status = ["stage": stage]
      status["error"] = error
      status["speakerCount"] = speakerCount.map(String.init)
      if let data = try? JSONEncoder().encode(status) {
        try? data.write(to: progress, options: .atomic)
      }
    }
    do {
      guard !FileManager.default.fileExists(atPath: output.path) else {
        throw TranscriptionFailure(message: "Output already exists.")
      }
      report("Preparing speaker models")
      let diarizer = OfflineDiarizerManager(config: .default)
      try await diarizer.prepareModels()
      report("Identifying speakers")
      let diarization = try await diarizer.process(input)
      let turns = diarization.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
      speakerCount = Set(turns.map(\.speakerId)).count
      guard !turns.isEmpty else {
        throw TranscriptionFailure(message: "No speech was detected in the recording.")
      }
      report("Preparing Parakeet TDT v3")
      let models = try await AsrModels.downloadAndLoad(version: .v3)
      let asr = AsrManager(models: models)
      let audio = try AVAudioFile(forReading: input)
      let rate = audio.processingFormat.sampleRate
      let converter = AudioConverter()
      var labels: [String: Int] = [:]
      var lines: [String] = []
      for (index, turn) in turns.enumerated() {
        report("Transcribing speaker turn \(index + 1)/\(turns.count)")
        if labels[turn.speakerId] == nil { labels[turn.speakerId] = labels.count + 1 }
        let start = max(0, Double(turn.startTimeSeconds))
        let end = min(Double(audio.length) / rate, Double(turn.endTimeSeconds))
        guard end > start else { continue }
        var texts: [String] = []
        var position = AVAudioFramePosition(start * rate)
        let last = AVAudioFramePosition(end * rate)
        while position < last {
          let count = AVAudioFrameCount(min(last - position, AVAudioFramePosition(30 * rate)))
          guard
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count)
          else { throw TranscriptionFailure(message: "Cannot allocate transcription audio.") }
          audio.framePosition = position
          try audio.read(into: buffer, frameCount: count)
          guard buffer.frameLength > 0 else {
            throw TranscriptionFailure(message: "Recording ended unexpectedly.")
          }
          let samples = try converter.resampleBuffer(buffer)
          var decoderState = try TdtDecoderState()
          let result = try await asr.transcribe(samples, decoderState: &decoderState)
          let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty { texts.append(text) }
          position += AVAudioFramePosition(buffer.frameLength)
        }
        guard !texts.isEmpty else { continue }
        let seconds = Int(start)
        let timestamp = String(
          format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        lines.append(
          "[\(timestamp)] Speaker \(labels[turn.speakerId]!): \(texts.joined(separator: " "))")
      }
      guard !lines.isEmpty else {
        throw TranscriptionFailure(message: "No speech was recognized in the recording.")
      }
      try Data((lines.joined(separator: "\n\n") + "\n").utf8).write(
        to: output, options: .withoutOverwriting)
      report("Complete")
    } catch {
      report("Failed", error: error.localizedDescription)
      exit(1)
    }
  }
}

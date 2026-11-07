import AVFoundation
import Foundation

struct NoSpeechDetected: LocalizedError {
  var errorDescription: String? { "No speech was detected in the recording." }
}

@MainActor
final class NativeTranscriber {
  private var process: Process?
  /// Receives each new helper stage, such as "Transcribing part 3/11".
  var onProgress: ((String) -> Void)?

  nonisolated static func duration(of file: URL) throws -> TimeInterval {
    let audio = try AVAudioFile(forReading: file)
    return Double(audio.length) / audio.processingFormat.sampleRate
  }

  nonisolated static func failure(status: [String: String], code: Int32) -> Error {
    if status["noSpeech"] == "true" { return NoSpeechDetected() }
    return MeetingError(
      status["error"]
        ?? "Local transcription stopped during \(status["stage"] ?? "startup") (code \(code)). Choose Retry to try again."
    )
  }

  func cancel() {
    if let process, process.isRunning { process.terminate() }
  }

  /// Transcribes `file`. With a `capture` directory that holds separate microphone and Teams
  /// tracks, the helper transcribes each track on its own.
  func transcribe(file: URL, capture: URL? = nil, executable: URL? = nil) async throws
    -> TranscriptSegments
  {
    let executable =
      executable
      ?? Bundle.main.bundleURL
      .appendingPathComponent("Contents/MacOS/MeetingTranscriber")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw MeetingError("The local transcription engine is missing. Reinstall Meeting Notes.")
    }
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("meeting-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let output = temporary.appendingPathComponent("segments.json")
    let progress = temporary.appendingPathComponent("progress.json")
    let task = Process()
    task.executableURL = executable
    task.arguments = [file.path, output.path, progress.path] + (capture.map { [$0.path] } ?? [])
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    process = task
    defer {
      cancel()
      process = nil
    }
    try task.run()
    var lastProgress = ""
    func readProgress() -> [String: String] {
      guard let data = try? Data(contentsOf: progress),
        let status = try? JSONDecoder().decode([String: String].self, from: data)
      else { return [:] }
      if let message = status["stage"], message != lastProgress {
        AppLog.event("native.progress", message)
        lastProgress = message
        onProgress?(message)
      }
      return status
    }
    while task.isRunning {
      try Task.checkCancellation()
      _ = readProgress()
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    try Task.checkCancellation()
    let status = readProgress()
    AppLog.event(
      "native.exit",
      "code=\(task.terminationStatus); stage=\(status["stage"] ?? "starting"); speakers=\(status["speakerCount"] ?? "unknown")"
    )
    guard task.terminationStatus == 0 else {
      throw Self.failure(status: status, code: task.terminationStatus)
    }
    let result = try JSONDecoder().decode(TranscriptSegments.self, from: Data(contentsOf: output))
    guard !result.segments.isEmpty else { throw NoSpeechDetected() }
    AppLog.event(
      "native.result",
      "mode=\(result.mode.rawValue); segments=\(result.segments.count); echoCoupling=\(result.echo.map { String(format: "%.3f", $0.coupling) } ?? "n/a")"
    )
    return result
  }
}

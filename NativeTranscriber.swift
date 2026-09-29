import AVFoundation
import Foundation

struct NoSpeechDetected: LocalizedError {
  var errorDescription: String? { "No speech was detected in the recording." }
}

@MainActor
final class NativeTranscriber {
  private var process: Process?

  nonisolated static func duration(of file: URL) throws -> TimeInterval {
    let audio = try AVAudioFile(forReading: file)
    return Double(audio.length) / audio.processingFormat.sampleRate
  }

  nonisolated static func failure(status: [String: String], code: Int32) -> Error {
    if status["noSpeech"] == "true" { return NoSpeechDetected() }
    return MeetingError(
      status["error"]
        ?? "Local transcription stopped during \(status["stage"] ?? "startup") (code \(code)). Retry Transcription."
    )
  }

  func cancel() {
    if let process, process.isRunning { process.terminate() }
  }

  func transcribe(file: URL, executable: URL? = nil) async throws -> String {
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
    let output = temporary.appendingPathComponent("transcript.txt")
    let progress = temporary.appendingPathComponent("progress.json")
    let task = Process()
    task.executableURL = executable
    task.arguments = [file.path, output.path, progress.path]
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
    let text = try String(contentsOf: output, encoding: .utf8)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NoSpeechDetected()
    }
    return text
  }
}

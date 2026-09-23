import Foundation

@MainActor
final class NativeTranscriber {
  private var process: Process?

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
      throw MeetingError(
        status["error"]
          ?? "Local transcription stopped during \(status["stage"] ?? "startup") (code \(task.terminationStatus)). Retry Transcription."
      )
    }
    let text = try String(contentsOf: output, encoding: .utf8)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MeetingError("No speech was recognized in the recording.")
    }
    return text
  }
}

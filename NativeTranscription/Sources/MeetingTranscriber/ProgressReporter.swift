import Foundation

/// Writes the helper's progress file, which the app polls: the current stage and, at the end,
/// an error or the number of speakers.
final class ProgressReporter: @unchecked Sendable {
  private let file: URL
  private let lock = NSLock()
  private var lastStage = ""
  var speakerCount: Int?

  init(file: URL) { self.file = file }

  func report(_ stage: String, error: String? = nil, noSpeech: Bool = false) {
    lock.withLock {
      guard stage != lastStage || error != nil else { return }
      lastStage = stage
      var status = ["stage": stage]
      status["error"] = error
      status["noSpeech"] = noSpeech ? "true" : nil
      status["speakerCount"] = speakerCount.map(String.init)
      if let data = try? JSONEncoder().encode(status) {
        try? data.write(to: file, options: .atomic)
      }
    }
  }
}

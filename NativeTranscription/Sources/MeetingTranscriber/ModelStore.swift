import CryptoKit
import Foundation

/// A model file downloaded on first use from a pinned revision and verified by its SHA-256.
struct ModelFile: Sendable {
  let name: String
  let url: URL
  let sha256: String
  let size: Int64

  static let whisper = ModelFile(
    name: "ggml-large-v3-turbo-q5_0.bin",
    url: URL(
      string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
    )!,
    sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    size: 574_041_195)

  static let silero = ModelFile(
    name: "ggml-silero-v5.1.2.bin",
    url: URL(
      string:
        "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"
    )!,
    sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
    size: 885_098)
}

/// Keeps models in `~/Library/Application Support/Meeting Notes/Models`. A file is only ever
/// placed there after its checksum matched, and it is verified again before every use, so a
/// damaged or replaced file is downloaded again instead of being loaded.
enum ModelStore {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Meeting Notes/Models", isDirectory: true)
  }

  /// Returns the verified local copy of `file`, downloading it if needed. `progress` receives the
  /// downloaded fraction.
  static func ensure(_ file: ModelFile, progress: @escaping @Sendable (Double) -> Void)
    async throws -> URL
  {
    let manager = FileManager.default
    let destination = directory.appendingPathComponent(file.name)
    if manager.fileExists(atPath: destination.path) {
      if try matches(destination, file) { return destination }
      try manager.removeItem(at: destination)
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let partial = directory.appendingPathComponent(".\(file.name).\(UUID().uuidString).partial")
    defer { try? manager.removeItem(at: partial) }
    do {
      try await download(file.url, to: partial, expectedSize: file.size, progress: progress)
    } catch {
      throw TranscriptionFailure(
        message:
          "The transcription model could not be downloaded (\(error.localizedDescription)). Meeting Notes needs internet access once to download it."
      )
    }
    guard try matches(partial, file) else {
      throw TranscriptionFailure(
        message: "The downloaded transcription model is damaged. Choose Retry to download it again."
      )
    }
    do {
      try manager.moveItem(at: partial, to: destination)
    } catch  where manager.fileExists(atPath: destination.path) {
      // Another transcription downloaded the same model at the same time.
      guard try matches(destination, file) else { throw error }
    }
    return destination
  }

  static func matches(_ url: URL, _ file: ModelFile) throws -> Bool {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
    guard Int64(size) == file.size else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
  }

  private static func download(
    _ url: URL, to destination: URL, expectedSize: Int64,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let received = ReceivedBytes()
    let monitor = Task {
      while !Task.isCancelled {
        progress(min(1, Double(received.count) / Double(max(1, expectedSize))))
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }
    defer { monitor.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let task = URLSession.shared.downloadTask(with: url) { location, response, error in
        if let error { return continuation.resume(throwing: error) }
        guard let location, let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode)
        else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          return continuation.resume(throwing: TranscriptionFailure(message: "HTTP \(code)"))
        }
        do {
          try FileManager.default.moveItem(at: location, to: destination)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
      received.task = task
      task.resume()
    }
  }

  private final class ReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionDownloadTask?
    var task: URLSessionDownloadTask? {
      get { lock.withLock { _task } }
      set { lock.withLock { _task = newValue } }
    }
    var count: Int64 { task?.countOfBytesReceived ?? 0 }
  }
}

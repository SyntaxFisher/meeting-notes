import AppKit
import Foundation

final class FluidVoiceClient {
  private let session: URLSession
  private let baseURL: URL

  init() {
    let port = UserDefaults(suiteName: "com.FluidApp.app")?.integer(forKey: "LocalAPIPort") ?? 0
    baseURL = URL(string: "http://127.0.0.1:\(port > 0 ? port : 47733)")!
    let settings = URLSessionConfiguration.ephemeral
    settings.timeoutIntervalForRequest = 3_600
    settings.timeoutIntervalForResource = 3_600
    session = URLSession(configuration: settings)
  }

  func health() async throws {
    let url = baseURL.appendingPathComponent("v1/health")
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let (data, response) = try await session.data(for: request)
    AppLog.event("fluid.health", "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      body["status"] as? String == "ok"
    else {
      throw MeetingError("FluidVoice's local API is not ready.")
    }
  }

  func transcribe(file: URL) async throws -> String {
    AppLog.event("fluid.transcribe", file.path)
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcribe"))
    request.httpMethod = "POST"
    request.timeoutInterval = 3_600
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["path": file.path])
    let (data, response) = try await session.data(for: request)
    let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    AppLog.event("fluid.response", "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw MeetingError("FluidVoice: \(result?["error"] as? String ?? "transcription failed")")
    }
    guard let text = result?["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MeetingError("FluidVoice returned an empty transcript.")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum AppLauncher {
  static let obsID = "com.obsproject.obs-studio"
  static let fluidID = "com.FluidApp.app"

  static func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  @discardableResult
  static func openIfNeeded(bundleID: String, path: String, hidden: Bool = false) async throws
    -> Bool
  {
    AppLog.event("app.open", "\(bundleID); running=\(isRunning(bundleID)); hidden=\(hidden)")
    if isRunning(bundleID) {
      if hidden { hide(bundleID) }
      return false
    }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw MeetingError("Required app is not installed: \(url.lastPathComponent).")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = !hidden
    configuration.hides = hidden
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
        app, error in
        if let error {
          continuation.resume(throwing: error)
        } else if app == nil {
          continuation.resume(throwing: MeetingError("Could not open \(url.lastPathComponent)."))
        } else {
          if hidden { _ = app?.hide() }
          continuation.resume()
        }
      }
    }
    return true
  }

  static func hide(_ bundleID: String) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
      _ = app.hide()
    }
  }

  static func closeIfLaunched(_ bundleID: String, launched: Bool) {
    guard launched else { return }
    AppLog.event("app.close", bundleID)
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
      app.terminate()
    }
  }
}

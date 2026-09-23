import CryptoKit
import Foundation

final class OBSClient {
  private let session: URLSession
  private let socket: URLSessionWebSocketTask

  private init(session: URLSession, socket: URLSessionWebSocketTask) {
    self.session = session
    self.socket = socket
  }

  static func connect() async throws -> OBSClient {
    AppLog.event("obs.connect")
    let configURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
    let config =
      try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
    guard config?["server_enabled"] as? Bool == true else {
      throw MeetingError(
        "Enable the OBS WebSocket server in OBS → Tools → WebSocket Server Settings.")
    }
    guard config?["auth_required"] as? Bool == true,
      let password = config?["server_password"] as? String, !password.isEmpty
    else {
      throw MeetingError("OBS WebSocket authentication must be enabled with a password.")
    }
    let port = config?["server_port"] as? Int ?? 4455
    guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
      throw MeetingError("Invalid OBS WebSocket port.")
    }
    let settings = URLSessionConfiguration.ephemeral
    settings.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: settings)
    let socket = session.webSocketTask(with: url, protocols: ["obswebsocket.json"])
    let client = OBSClient(session: session, socket: socket)
    socket.resume()
    do {
      let hello = try await client.receive()
      guard hello["op"] as? Int == 0, let data = hello["d"] as? [String: Any],
        let authentication = data["authentication"] as? [String: Any],
        let salt = authentication["salt"] as? String,
        let challenge = authentication["challenge"] as? String
      else {
        throw MeetingError("OBS sent an unexpected WebSocket handshake.")
      }
      let secret = digest(password + salt)
      let response = digest(secret + challenge)
      try await client.send([
        "op": 1,
        "d": [
          "rpcVersion": 1,
          "eventSubscriptions": 0,
          "authentication": response,
        ],
      ])
      let identified = try await client.receive()
      guard identified["op"] as? Int == 2 else {
        throw MeetingError("OBS WebSocket authentication failed.")
      }
      return client
    } catch {
      AppLog.event("obs.connectFailed", error.localizedDescription)
      client.close()
      throw error
    }
  }

  func close() {
    socket.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }

  func request(_ type: String, _ data: [String: Any] = [:]) async throws -> [String: Any] {
    var succeeded = false
    defer {
      if !succeeded || !type.hasPrefix("Get") {
        AppLog.event("obs.request", "\(type); success=\(succeeded)")
      }
    }
    let id = UUID().uuidString
    var payload: [String: Any] = ["requestType": type, "requestId": id]
    if !data.isEmpty { payload["requestData"] = data }
    try await send(["op": 6, "d": payload])
    let message = try await receive()
    guard message["op"] as? Int == 7,
      let result = message["d"] as? [String: Any],
      result["requestId"] as? String == id,
      let status = result["requestStatus"] as? [String: Any]
    else {
      throw MeetingError("OBS returned an unexpected response to \(type).")
    }
    guard status["result"] as? Bool == true else {
      throw MeetingError("OBS \(type): \(status["comment"] as? String ?? "request failed")")
    }
    succeeded = true
    return result["responseData"] as? [String: Any] ?? [:]
  }

  func isRecording() async throws -> Bool {
    try await request("GetRecordStatus")["outputActive"] as? Bool == true
  }

  func isStreaming() async throws -> Bool {
    try await request("GetStreamStatus")["outputActive"] as? Bool == true
  }

  static func waitUntilStopped(
    attempts: Int = 80, interval: UInt64 = 250_000_000,
    isRecording: () async throws -> Bool
  ) async throws {
    var inactiveChecks = 0
    for _ in 0..<attempts {
      try Task.checkCancellation()
      inactiveChecks = try await isRecording() ? 0 : inactiveChecks + 1
      // Allow the output writer to finish closing after OBS changes its active flag.
      if inactiveChecks == 2 { return }
      try await Task.sleep(nanoseconds: interval)
    }
    throw MeetingError("OBS is still finishing the MP3. Wait a moment, then Retry Transcription.")
  }

  func repairAudioSetup(microphoneMuted: Bool) async throws {
    let movies = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
      .path
    let values: [(String, String, String)] = [
      ("Output", "Mode", "Advanced"),
      ("AdvOut", "RecType", "FFmpeg"),
      ("AdvOut", "RecEncoder", "none"),
      ("AdvOut", "FFOutputToFile", "true"),
      ("AdvOut", "FFFilePath", movies),
      ("AdvOut", "FFFormat", "mp3"),
      ("AdvOut", "FFFormatMimeType", "audio/mpeg"),
      ("AdvOut", "FFExtension", "mp3"),
      ("AdvOut", "FFVEncoderId", "0"),
      ("AdvOut", "FFVEncoder", ""),
      ("AdvOut", "FFAEncoderId", "86017"),
      ("AdvOut", "FFAEncoder", "libmp3lame"),
      ("AdvOut", "FFAudioMixes", "1"),
    ]
    for (category, name, value) in values {
      let argument = ["parameterCategory": category, "parameterName": name]
      let current = try await request("GetProfileParameter", argument)
      if current["parameterValue"] as? String != value {
        _ = try await request(
          "SetProfileParameter", argument.merging(["parameterValue": value]) { _, new in new })
      }
    }
    for name in ["Mic/Aux", "macOS Audio Capture"] {
      let argument = ["inputName": name]
      let desiredMuted = name == "Mic/Aux" && microphoneMuted
      let muted: [String: Any]
      do { muted = try await request("GetInputMute", argument) } catch {
        throw MeetingError(
          "OBS is missing \(name). Restore the audio source and its macOS permission.")
      }
      if muted["inputMuted"] as? Bool != desiredMuted {
        _ = try await request("SetInputMute", ["inputName": name, "inputMuted": desiredMuted])
      }
      let monitoring = try await request("GetInputAudioMonitorType", argument)
      if monitoring["monitorType"] as? String != "OBS_MONITORING_TYPE_NONE" {
        _ = try await request(
          "SetInputAudioMonitorType",
          [
            "inputName": name,
            "monitorType": "OBS_MONITORING_TYPE_NONE",
          ])
      }
      let tracks = try await request("GetInputAudioTracks", argument)
      if var enabled = tracks["inputAudioTracks"] as? [String: Bool], enabled["1"] != true {
        enabled["1"] = true
        _ = try await request(
          "SetInputAudioTracks", ["inputName": name, "inputAudioTracks": enabled])
      }
    }
    let scene = try await request("GetCurrentProgramScene")
    guard let sceneName = scene["currentProgramSceneName"] as? String else {
      throw MeetingError("OBS has no active scene.")
    }
    let items = try await request("GetSceneItemList", ["sceneName": sceneName])
    guard
      let audio = (items["sceneItems"] as? [[String: Any]])?.first(where: {
        $0["sourceName"] as? String == "macOS Audio Capture"
      }), let id = audio["sceneItemId"] as? Int
    else {
      throw MeetingError("OBS's active scene is missing macOS Audio Capture.")
    }
    if audio["sceneItemEnabled"] as? Bool != true {
      _ = try await request(
        "SetSceneItemEnabled",
        [
          "sceneName": sceneName,
          "sceneItemId": id, "sceneItemEnabled": true,
        ])
    }
    let directory = try await request("GetRecordDirectory")
    guard directory["recordDirectory"] as? String == movies else {
      throw MeetingError("OBS's recording directory is not Movies. Restart OBS and try again.")
    }
  }

  private func send(_ value: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    guard let text = String(data: data, encoding: .utf8) else {
      throw MeetingError("Invalid OBS request.")
    }
    try await socket.send(.string(text))
  }

  private func receive() async throws -> [String: Any] {
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let bytes): data = bytes
    @unknown default: throw MeetingError("Unknown OBS WebSocket message.")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw MeetingError("Invalid OBS response.")
    }
    return object
  }

  private static func digest(_ text: String) -> String {
    Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
  }
}

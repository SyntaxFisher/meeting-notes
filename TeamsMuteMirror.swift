import Foundation

@MainActor
final class TeamsMuteMirror {
  private var client: OBSClient?
  private var task: Task<Void, Never>?
  private let reportWarning: @MainActor (String?) -> Void
  private var previousState: TeamsMuteState?

  init(client: OBSClient?, reportWarning: @escaping @MainActor (String?) -> Void) {
    self.client = client
    self.reportWarning = reportWarning
  }

  func start() {
    task = Task { await run() }
  }

  func stop() {
    task?.cancel()
    task = nil
    client?.close()
    client = nil
    reportWarning(nil)
  }

  private func run() async {
    while !Task.isCancelled {
      let state = TeamsMuteReader.read()
      if state != previousState {
        AppLog.event("teams.detection", String(describing: state))
        previousState = state
      }
      do {
        if client == nil { client = try await OBSClient.connect() }
        guard !Task.isCancelled, let client else { break }
        let current = try await client.request("GetInputMute", ["inputName": "Mic/Aux"])
        guard let muted = current["inputMuted"] as? Bool else {
          throw MeetingError("OBS did not return the microphone mute state.")
        }
        if muted != state.obsMicrophoneMuted {
          AppLog.event("teams.mirror", "OBS mic muted=\(state.obsMicrophoneMuted)")
          _ = try await client.request(
            "SetInputMute",
            ["inputName": "Mic/Aux", "inputMuted": state.obsMicrophoneMuted])
        }
        guard !Task.isCancelled else { break }
        switch state {
        case .muted, .unmuted: reportWarning(nil)
        case .unavailable(let reason):
          reportWarning("Teams mute unavailable: \(reason.message) OBS mic stays on.")
        }
      } catch {
        guard !Task.isCancelled else { break }
        client?.close()
        client = nil
        reportWarning("Cannot control OBS mic: \(error.localizedDescription)")
      }
      try? await Task.sleep(nanoseconds: 400_000_000)
    }
  }
}

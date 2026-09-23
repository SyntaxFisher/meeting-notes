import Foundation

@MainActor
final class TeamsMuteMirror {
  private let recorder: NativeRecorder
  private var task: Task<Void, Never>?
  private(set) var currentState: TeamsMuteState?
  var onStateChanged: (() -> Void)?
  init(recorder: NativeRecorder) { self.recorder = recorder }
  func start() {
    update()
    task = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        update()
      }
    }
  }
  func stop() {
    task?.cancel()
    task = nil
  }
  private func update() {
    let state = TeamsMuteReader.read()
    if state != currentState {
      AppLog.event("teams.detection", String(describing: state))
      currentState = state
      onStateChanged?()
    }
    recorder.setMicrophoneMuted(state.microphoneMuted)
  }
}

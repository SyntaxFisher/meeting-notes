import Foundation

@MainActor
final class TeamsMonitor {
  private var task: Task<Void, Never>?
  private(set) var currentState: TeamsMuteState?
  /// Receives the detected Teams mute state on every reading while set.
  var mirroredRecorder: NativeRecorder? {
    didSet { if isRunning, mirroredRecorder != nil { update() } }
  }
  var onStateChanged: (() -> Void)?
  var onReading: (() -> Void)?
  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil else { return }
    update()
    task = Task {
      while !Task.isCancelled {
        let interval: UInt64 = mirroredRecorder == nil ? 2_000_000_000 : 400_000_000
        try? await Task.sleep(nanoseconds: interval)
        guard !Task.isCancelled else { return }
        update()
      }
    }
  }
  func stop() {
    task?.cancel()
    task = nil
    currentState = nil
  }
  private func update() {
    let state = TeamsMuteReader.read()
    mirroredRecorder?.setMicrophoneMuted(state.microphoneMuted)
    if state != currentState {
      AppLog.event("teams.detection", String(describing: state))
      currentState = state
      onStateChanged?()
    }
    onReading?()
  }
}

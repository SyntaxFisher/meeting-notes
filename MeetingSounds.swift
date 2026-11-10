import AppKit

enum MeetingSound: String {
  case start = "Purr"
  case stop = "Frog"
  case discard = "Pop"
  case complete = "Blow"
  case error = "Basso"

  static func forEvent(
    _ event: LifecycleEvent, status: MeetingStatus, failed: Bool = false
  ) -> MeetingSound? {
    switch event {
    case .recordingStarted: return .start
    case .recordingStopped: return failed ? .error : .stop
    case .recordingDiscarded: return status == .recording ? .discard : nil
    case .meetingDiscarded: return .discard
    case .transcriptReady: return .complete
    case .recordingFailed, .recordingInterrupted, .transcriptionFailed: return .error
    case .transcriptionQueued, .transcriptionStarted, .meetingDeleted: return nil
    }
  }
}

@MainActor
final class MeetingSounds {
  var isEnabled = true {
    didSet {
      if !isEnabled {
        current?.stop()
        current = nil
        lastErrorAt = nil
      }
    }
  }

  private let output: ((MeetingSound) -> Void)?
  private var current: NSSound?
  private var lastErrorAt: TimeInterval?

  init(output: ((MeetingSound) -> Void)? = nil) {
    self.output = output
  }

  func play(_ cue: MeetingSound, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard isEnabled else { return }
    // One failure can surface through both the recording lifecycle and its command result.
    if cue == .error {
      if let lastErrorAt, now - lastErrorAt < 2 { return }
      lastErrorAt = now
    }
    if let output {
      output(cue)
      return
    }
    current?.stop()
    current = NSSound(
      contentsOfFile: "/System/Library/Sounds/\(cue.rawValue).aiff", byReference: true)
    current?.volume = 0.1
    if current?.play() != true {
      AppLog.event("sound.unavailable", cue.rawValue)
    }
  }
}

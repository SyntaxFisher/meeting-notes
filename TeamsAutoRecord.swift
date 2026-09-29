import Foundation

enum TeamsMeetingPresence {
  case inMeeting
  case noMeeting
  case unknown
}

extension TeamsMuteState {
  var meetingPresence: TeamsMeetingPresence {
    switch self {
    case .muted, .unmuted, .unavailable(.noControl): return .inMeeting
    case .unavailable(.noMeeting), .unavailable(.teamsClosed): return .noMeeting
    case .unavailable(.accessibilityPermission), .unavailable(.ambiguous),
      .unavailable(.accessibilityError):
      return .unknown
    }
  }
}

/// Starts a recording when a Teams meeting is detected and stops it once the meeting has been
/// gone for the grace period. Only recordings it started are stopped. When any recording ends
/// while a meeting may still be running, no new recording starts until that meeting ends.
struct TeamsAutoRecordPolicy {
  enum Action { case start, stop }

  static let leaveGracePeriod: TimeInterval = 5
  private(set) var ownsRecording = false
  private var waitingForMeetingEnd = false
  private var lastPresence: TeamsMeetingPresence = .unknown
  private var absentSince: Date?

  mutating func observe(
    _ presence: TeamsMeetingPresence, at now: Date, isRecording: Bool, canStart: Bool
  ) -> Action? {
    lastPresence = presence
    switch presence {
    case .inMeeting:
      absentSince = nil
      return !isRecording && canStart && !waitingForMeetingEnd ? .start : nil
    case .noMeeting:
      waitingForMeetingEnd = false
      guard isRecording, ownsRecording else { return nil }
      let since = absentSince ?? now
      absentSince = since
      return now.timeIntervalSince(since) >= Self.leaveGracePeriod ? .stop : nil
    case .unknown:
      return nil
    }
  }

  mutating func recordingStarted(automatically: Bool) {
    ownsRecording = automatically
    absentSince = nil
  }

  mutating func recordingEnded() {
    ownsRecording = false
    absentSince = nil
    waitingForMeetingEnd = lastPresence != .noMeeting
  }
}

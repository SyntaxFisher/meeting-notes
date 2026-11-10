import Foundation

enum TeamsScreenSharingSmoke {
  static func run() {
    for title in ["Share content", "Inhalt freigeben", "Inhalte freigeben", "Inhalt teilen"] {
      precondition(TeamsMuteClassifier.isSharingPicker(role: "AXHeading", labels: [title]))
      precondition(!TeamsMuteClassifier.isSharingPicker(role: "AXButton", labels: [title]))
    }
    precondition(!TeamsMuteClassifier.isSharingPicker(role: "AXHeading", labels: ["Window"]))

    let picker = TeamsWindowSnapshot(
      title: "Weekly Sync", buttons: [], sharingPicker: true)
    let toolbar = TeamsWindowSnapshot(buttons: [["Stop sharing"]], isCurrent: true)
    let germanToolbar = TeamsWindowSnapshot(buttons: [["Freigabe beenden"]], isCurrent: true)
    let meeting = TeamsWindowSnapshot(title: "Weekly Sync", buttons: [["Leave"], ["Unmute mic"]])
    var tracker = TeamsMeetingWindowTracker<Int>()
    precondition(tracker.observe([(1, meeting)]).state == .muted)
    for title in ["Weekly Sync", "Chat", "Meeting compact view | Weekly Sync", ""] {
      let obscured = TeamsWindowSnapshot(title: title, buttons: [["More options"]])
      let reading = tracker.observe([(1, obscured)])
      precondition(reading.state.meetingPresence == .inMeeting)
      precondition(reading.state.microphoneMuted == nil)
    }
    let chat = TeamsWindowSnapshot(title: "Chat", buttons: [])
    precondition(tracker.observe([(2, chat)]).state == .unavailable(.noMeeting))
    precondition(tracker.observe([(1, chat), (2, chat)]).state == .unavailable(.noMeeting))
    precondition(tracker.observe([(3, meeting)]).state == .muted)
    let ended = TeamsWindowSnapshot(
      title: "Weekly Sync", buttons: [["Rejoin the call"], ["Dismiss"]], meetingEnded: true)
    precondition(tracker.observe([(3, ended)]).state == .unavailable(.noMeeting))
    precondition(tracker.observe([(3, chat)]).state == .unavailable(.noMeeting))
    precondition(tracker.observe([(3, meeting)]).state == .muted)
    precondition(tracker.observe([(4, toolbar)]).state.meetingPresence == .inMeeting)
    precondition(tracker.observe([]).state == .unavailable(.noMeeting))
    for label in ["Rejoin the call", "Rejoin", "Erneut beitreten", "Erneut teilnehmen"] {
      precondition(TeamsMuteClassifier.isMeetingEndControl([label]))
    }
    precondition(!TeamsMuteClassifier.isMeetingEndControl(["Join now"]))
    for automatically in [false, true] {
      var stopping = TeamsAutoRecordPolicy()
      stopping.recordingStarted(automatically: automatically)
      precondition(
        stopping.observe(.inMeeting, at: Date(), isRecording: false, canStart: true) == nil,
        "Closing capture tracks must not start a replacement recording before the stop event")
      stopping.recordingEnded()
      precondition(
        stopping.observe(.inMeeting, at: Date(), isRecording: false, canStart: true) == nil)
    }
    var policy = TeamsAutoRecordPolicy()
    policy.recordingStarted(automatically: true)
    let start = Date(timeIntervalSince1970: 0)
    for (index, window) in [meeting, picker, toolbar, germanToolbar, picker, meeting].enumerated() {
      let state = TeamsMuteClassifier.classify([window])
      precondition(state.meetingPresence == .inMeeting)
      precondition(
        policy.observe(
          state.meetingPresence, at: start + Double(index) * 10,
          isRecording: true, canStart: false) == nil,
        "Choosing, sharing and stopping sharing must preserve the same recording")
    }
    precondition(TeamsMuteClassifier.classify([picker]).microphoneMuted == nil)
    precondition(TeamsMuteClassifier.meetingTitle([picker]) == "Weekly Sync")
    let left = start + 60
    precondition(policy.observe(.noMeeting, at: left, isRecording: true, canStart: false) == nil)
    precondition(
      policy.observe(
        .noMeeting, at: left + TeamsAutoRecordPolicy.leaveGracePeriod,
        isRecording: true, canStart: false) == .stop)
    print(
      "Screen-sharing picker and presenter toolbar preserve recording and unknown mute state: OK")
  }
}

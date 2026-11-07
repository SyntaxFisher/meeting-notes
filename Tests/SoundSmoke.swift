import AppKit

enum SoundSmoke {
  @MainActor
  static func run() {
    var played: [MeetingSound] = []
    let sounds = MeetingSounds { played.append($0) }
    let sequence: [(LifecycleEvent, MeetingStatus, Bool)] = [
      (.recordingStarted, .recording, false),
      (.recordingStopped, .saving, false),
      (.transcriptionQueued, .queued, false),
      (.transcriptionStarted, .transcribing, false),
      (.transcriptReady, .complete, false),
      (.meetingDeleted, .complete, false),
      (.recordingStarted, .recording, false),
      (.recordingDiscarded, .recording, false),
      (.meetingDiscarded, .transcribing, false),
      (.recordingDiscarded, .transcribing, false),
      (.recordingStopped, .saving, true),
      (.recordingFailed, .failed, true),
    ]
    for (event, status, failed) in sequence {
      if let cue = MeetingSound.forEvent(event, status: status, failed: failed) {
        sounds.play(cue, now: 10)
      }
    }
    precondition(played == [.start, .stop, .complete, .start, .discard, .discard, .error])
    sounds.play(.error, now: 11)
    precondition(played.count == 7, "A repeated failure must not play another error sound")
    sounds.play(.error, now: 12)
    precondition(played.count == 8, "A later failure must still be audible")
    for event in [LifecycleEvent.recordingInterrupted, .transcriptionFailed] {
      precondition(MeetingSound.forEvent(event, status: .failed) == .error)
    }
    for cue in [MeetingSound.start, .stop, .discard, .complete, .error] {
      let sound = NSSound(
        contentsOfFile: "/System/Library/Sounds/\(cue.rawValue).aiff", byReference: true)
      precondition(sound != nil && sound!.duration > 0, "System sound must be loadable")
    }
    print("Lifecycle sounds, silent deletion and cleanup, and repeated-error suppression: OK")
  }
}

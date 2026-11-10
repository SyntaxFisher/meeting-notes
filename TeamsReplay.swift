import Foundation

/// Runs the current Teams detection over a `TeamsTrace` and sets the result next to what the
/// app recorded at the time: mute states, automatic recording starts and stops, and the
/// speakers Teams showed.
///
/// Automatic recording is simulated when the session's settings enable it: the policy sees
/// every reading the app made (`read` lines; changed readings also carry their input) and every
/// evaluation the app logged, in time order. Between them nothing is assumed: a reading the
/// trace does not show is unknown. Speakers are observed at every participant reading
/// (`participants-read`) with the last traced input; without such lines the replay gives no
/// speaker timeline. Whether a start was possible comes from the app's logged evaluations and
/// is unknown, so no start, before the first one. Automatic recordings start and stop as the
/// replayed policy decides; manual recordings, stops the user asked for, failures and
/// interruptions come from the trace, and a restart of the app, seen in a session line with
/// another process, ends the replayed recording and starts detection afresh. Readings Teams
/// never gave cannot be replayed, and the trace holds no audio.
enum TeamsReplay {
  struct Step: Codable, Equatable {
    var t: Double
    var value: String
  }

  struct Recording: Codable, Equatable {
    var start: Double
    var end: Double?
    var automatic: Bool
  }

  struct Side: Codable, Equatable {
    var states: [Step] = []
    var actions: [Step] = []
    var recordings: [Recording] = []
    var speakers: [Step] = []
  }

  struct Result: Codable, Equatable {
    var sessions: [[String: String]] = []
    var recorded = Side()
    var replayed = Side()
    /// The speaker timeline the replayed participant readings give, on the host clock like
    /// `speaking.json`.
    var speaking = SpeakingTimeline()
    /// How many participant readings the trace logs; without any, `speaking` says nothing.
    var participantReadings = 0
    var differences: [String] = []

    /// The speaker timeline a replay names voices with: the replayed one whenever the trace
    /// holds participant readings, even when they show nobody speaking.
    var replayedSpeaking: SpeakingTimeline? { participantReadings > 0 ? speaking : nil }
  }

  static func replay(_ trace: Data) -> Result {
    let lines = trace.split(separator: UInt8(ascii: "\n")).compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
    }.sorted { ($0["w"] as? Double ?? 0) < ($1["w"] as? Double ?? 0) }
    let tracesCommands = lines.contains { $0["k"] as? String == "command" }
    var process: Int?
    var currentSpeaker: String??
    var result = Result()
    var tracker = TeamsMeetingWindowTracker<Int>()
    var policy = TeamsAutoRecordPolicy()
    var presence: TeamsMeetingPresence?
    var autoRecord = true
    var canStart: Bool?
    var replayedState: String?
    var recordedState: String?
    var replayedSpeaker: String??
    var recordedSpeaker: String?
    var open: Int?
    var recordedOpen: Int?
    var lastAutomaticStop = -Double.infinity
    var lastStartAttempt = -Double.infinity
    var lastUserStop = -Double.infinity

    func evaluate(at time: Double) {
      guard autoRecord, let presence else { return }
      // The policy times the leave grace period with dates; trace times are seconds.
      guard
        let action = policy.observe(
          presence, at: Date(timeIntervalSinceReferenceDate: time), isRecording: open != nil,
          canStart: canStart ?? false)
      else { return }
      result.replayed.actions.append(Step(t: time, value: "\(action)"))
      switch action {
      case .start:
        policy.recordingStarted(automatically: true)
        result.replayed.recordings.append(Recording(start: time, automatic: true))
        open = result.replayed.recordings.count - 1
      case .stop: end(at: time)
      }
    }

    func end(at time: Double) {
      guard let index = open else { return }
      result.replayed.recordings[index].end = time
      open = nil
      policy.recordingEnded()
    }

    func noteSpeaker(_ speaker: String?, at time: Double) {
      guard speaker != replayedSpeaker else { return }
      result.replayed.speakers.append(Step(t: time, value: speaker ?? ""))
      replayedSpeaker = speaker
    }

    for line in lines {
      guard let kind = line["k"] as? String, let time = line["t"] as? Double else { continue }
      switch kind {
      case "session":
        result.sessions.append(line.compactMapValues { "\($0)" })
        // Settings changes and new trace files repeat the session; only a new process starts
        // the app's detection afresh.
        let pid = line["pid"] as? Int
        if let pid, let process, pid != process {
          end(at: time)
          tracker = TeamsMeetingWindowTracker<Int>()
          policy = TeamsAutoRecordPolicy()
        }
        process = pid ?? process
        if let enabled = (line["config"] as? [String: Any])?["autoRecordTeamsMeetings"] as? Bool {
          if enabled != autoRecord { policy = TeamsAutoRecordPolicy() }
          autoRecord = enabled
        }
      case "mute-input":
        guard let input = decode(TeamsMuteInput.self, line) else { continue }
        let state = TeamsMuteClassifier.reading(input, tracker: &tracker).state
        let description = state.name
        if description != replayedState {
          result.replayed.states.append(Step(t: time, value: description))
          replayedState = description
        }
        presence = state.meetingPresence
      case "read":
        evaluate(at: time)
      case "mute":
        if let state = line["state"] as? String, state != recordedState {
          result.recorded.states.append(Step(t: time, value: state))
          recordedState = state
        }
      case "auto-record":
        // The app logs each evaluation with what it knew then, such as whether a start was
        // possible; the replay evaluates at the same moment with that knowledge.
        canStart = line["canStart"] as? Bool ?? canStart
        if let action = line["action"] as? String, !action.isEmpty {
          result.recorded.actions.append(Step(t: time, value: action))
          if action == "stop" { lastAutomaticStop = time }
          if action == "start" { lastStartAttempt = time }
        }
        evaluate(at: time)
      case "command":
        let command = line["command"] as? String ?? ""
        let byUser = line["source"] as? String != "auto-record"
        if byUser,
          ["stop", "stop_and_discard"].contains(command)
            || (command == "toggle_recording" && open != nil)
        {
          lastUserStop = time
        }
      case "recording":
        let event = line["event"] as? String ?? ""
        let automatic = line["trigger"] as? String == "automatic"
        if event == LifecycleEvent.recordingStarted.rawValue {
          result.recorded.recordings.append(Recording(start: time, automatic: automatic))
          recordedOpen = result.recorded.recordings.count - 1
          if !automatic, open == nil {
            policy.recordingStarted(automatically: false)
            result.replayed.recordings.append(Recording(start: time, automatic: false))
            open = result.replayed.recordings.count - 1
          }
        } else if recordedOpen == nil {
          // A failed automatic start ends the attempt, as in the app; the replay's automatic
          // recording begun with that attempt would have failed the same way.
          if let index = open, result.replayed.recordings[index].automatic,
            result.replayed.recordings[index].start >= lastStartAttempt - 3
          {
            result.replayed.recordings.remove(at: index)
            open = nil
            policy.recordingEnded()
          }
        } else {
          guard let recorded = recordedOpen else { continue }
          let started = result.recorded.recordings[recorded].start
          result.recorded.recordings[recorded].end = time
          recordedOpen = nil
          // Manual recordings, stops the user asked for, failures and interruptions end the
          // replayed recording too; a stop the policy decided is the replay's own decision.
          let decidedByPolicy =
            event == LifecycleEvent.recordingStopped.rawValue
            && result.recorded.recordings[recorded].automatic
            && (tracesCommands ? lastUserStop < started : lastAutomaticStop >= time - 5)
          if !decidedByPolicy { end(at: time) }
        }
      case "participants-input":
        guard let input = decode(TeamsParticipantInput.self, line) else { continue }
        currentSpeaker = TeamsParticipantReader.snapshot(input)?.speaker
      case "participants-read":
        result.participantReadings += 1
        guard let speaker = currentSpeaker else { continue }
        result.speaking.observe(speaker, at: time)
        noteSpeaker(speaker, at: time)
      case "participants":
        if let speaker = line["speaker"] as? String, speaker != recordedSpeaker {
          result.recorded.speakers.append(Step(t: time, value: speaker))
          recordedSpeaker = speaker
        }
      default: break
      }
    }
    result.differences = differences(result)
    return result
  }

  private static func differences(_ result: Result) -> [String] {
    var lines: [String] = []
    func automatic(_ side: Side) -> [Recording] { side.recordings.filter(\.automatic) }
    let before = automatic(result.recorded)
    let after = automatic(result.replayed)
    if before.count != after.count {
      lines.append("automatic recordings: \(before.count) recorded, \(after.count) replayed")
    }
    for (old, new) in zip(before, after) {
      if abs(old.start - new.start) > 3 {
        lines.append(String(format: "start %.1f recorded, %.1f replayed", old.start, new.start))
      }
      if (old.end ?? .infinity) != (new.end ?? .infinity),
        abs((old.end ?? 1e12) - (new.end ?? 1e12)) > 3
      {
        lines.append(
          "stop \(old.end.map { String(format: "%.1f", $0) } ?? "none") recorded, "
            + "\(new.end.map { String(format: "%.1f", $0) } ?? "none") replayed")
      }
    }
    if result.recorded.states.map(\.value) != result.replayed.states.map(\.value) {
      lines.append(
        "mute states: \(result.recorded.states.count) recorded changes, "
          + "\(result.replayed.states.count) replayed")
    }
    if result.recorded.speakers.map(\.value) != result.replayed.speakers.map(\.value) {
      lines.append(
        "speakers: \(result.recorded.speakers.count) recorded changes, "
          + "\(result.replayed.speakers.count) replayed")
    }
    return lines
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, _ line: [String: Any])
    -> Value?
  {
    guard let data = try? JSONSerialization.data(withJSONObject: line) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}

import Foundation

/// Watches Teams through Accessibility. Every read runs on a background queue because a slow
/// Teams reply can take seconds; only the results reach the main actor. While a recording
/// mirrors the Teams mute state, the background reader mutes the microphone itself, so mute
/// mirroring never waits for the main thread.
@MainActor
final class TeamsMonitor {
  private let reader = TeamsBackgroundReader()
  private(set) var currentState: TeamsMuteState?
  private(set) var meetingTitle: String?
  /// The local user's display name in the most recent Teams participant list.
  private(set) var localParticipantName: String?
  var onStateChanged: (() -> Void)?
  var onReading: (() -> Void)?
  var onLocalParticipant: ((String) -> Void)?
  private(set) var isRunning = false

  /// Receives the detected Teams mute state on every reading while set.
  var mirroredRecorder: NativeRecorder? {
    didSet { reader.setMirroredRecorder(mirroredRecorder) }
  }

  init() {
    reader.deliver = { [weak self] reading in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(reading) } }
    }
    reader.deliverLocalName = { [weak self] name in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.localParticipantName != name else { return }
          self.localParticipantName = name
          self.onLocalParticipant?(name)
        }
      }
    }
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    reader.start()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    reader.stop()
    currentState = nil
    meetingTitle = nil
  }

  /// Reads Teams now instead of waiting for the next periodic reading, which may be two
  /// seconds old or, while the monitor was stopped, missing.
  func readState() async -> TeamsMuteState {
    await withCheckedContinuation { continuation in
      reader.readNow { continuation.resume(returning: $0) }
    }
  }

  /// Collects the Teams participant list into `file` until `stopRoster` is called.
  func startRoster(writingTo file: URL, startedAt: Date) {
    reader.setRoster(file: file, startedAt: startedAt)
  }

  /// Stops collecting and returns once the last roster write finished.
  func stopRoster() async {
    await withCheckedContinuation { continuation in
      reader.clearRoster { continuation.resume() }
    }
  }

  private func receive(_ reading: TeamsReading) {
    guard isRunning else { return }
    if reading.meetingTitle != meetingTitle {
      AppLog.event("teams.meetingTitle", reading.meetingTitle ?? "none")
      meetingTitle = reading.meetingTitle
    }
    if reading.state != currentState {
      AppLog.event("teams.detection", String(describing: reading.state))
      currentState = reading.state
      onStateChanged?()
    }
    onReading?()
  }
}

/// The Accessibility reads behind `TeamsMonitor`, on one serial queue: the mute state every
/// 0.4 s while recording and every 2 s otherwise, and the participant roster every 2 s while a
/// recording collects it.
final class TeamsBackgroundReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.teams", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var mirrored: NativeRecorder?
  private var roster: (file: URL, startedAt: Date, roster: ParticipantRoster)?
  private var lastStateRead = Date.distantPast
  private var lastRosterRead = Date.distantPast
  private var participantCount = 0
  var deliver: (@Sendable (TeamsReading) -> Void)?
  var deliverLocalName: (@Sendable (String) -> Void)?

  func start() {
    queue.async { [self] in
      guard timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: 0.4, leeway: .milliseconds(50))
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
      lastStateRead = .distantPast
    }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
  }

  func setMirroredRecorder(_ recorder: NativeRecorder?) {
    queue.async { [self] in
      mirrored = recorder
      lastStateRead = .distantPast
    }
  }

  func readNow(_ done: @escaping @Sendable (TeamsMuteState) -> Void) {
    queue.async { [self] in
      lastStateRead = Date()
      let reading = TeamsMuteReader.read()
      mirrored?.setMicrophoneMuted(reading.state.microphoneMuted)
      deliver?(reading)
      done(reading.state)
    }
  }

  func setRoster(file: URL, startedAt: Date) {
    queue.async { [self] in
      roster = (file, startedAt, ParticipantRoster())
      participantCount = 0
      lastRosterRead = .distantPast
    }
  }

  func clearRoster(_ done: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      roster = nil
      done()
    }
  }

  private func tick() {
    let now = Date()
    if now.timeIntervalSince(lastStateRead) >= (mirrored == nil && roster == nil ? 2 : 0.4) {
      lastStateRead = now
      let reading = TeamsMuteReader.read()
      mirrored?.setMicrophoneMuted(reading.state.microphoneMuted)
      deliver?(reading)
    }
    if var current = roster, now.timeIntervalSince(lastRosterRead) >= 2 {
      lastRosterRead = now
      guard let sightings = TeamsParticipantReader.read(),
        current.roster.observe(sightings, at: now.timeIntervalSince(current.startedAt))
      else { return }
      roster = current
      try? JSONEncoder().encode(current.roster).write(to: current.file, options: .atomic)
      if let name = current.roster.localParticipant?.name { deliverLocalName?(name) }
      if current.roster.participants.count != participantCount {
        participantCount = current.roster.participants.count
        AppLog.event(
          "teams.participants",
          "count=\(participantCount); fullRoster=\(current.roster.sawFullRoster); local=\(current.roster.localParticipant != nil)"
        )
      }
    }
  }
}

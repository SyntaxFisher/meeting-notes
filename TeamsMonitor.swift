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

  /// Collects the Teams participant list into `capture/participants.json` and when Teams shows
  /// each participant speaking into `capture/speaking.json`, until `stopRoster` is called.
  func startRoster(in capture: URL, startedAt: Date) {
    reader.setRoster(directory: capture, startedAt: startedAt)
  }

  /// Stops collecting and returns once the last write finished.
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
/// 0.4 s while recording and every 2 s otherwise, and while a recording collects them the
/// active speaker every 0.8 s and the participant roster every 2 s, from the same reading.
final class TeamsBackgroundReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.teams", qos: .userInitiated)
  private let muteReader = TeamsMuteReader()
  private var timer: DispatchSourceTimer?
  private var mirrored: NativeRecorder?
  private var collection: Collection?
  private var lastStateRead = Date.distantPast
  private var lastMeetingRead = Date.distantPast
  private var lastRosterRead = Date.distantPast

  private struct Collection {
    let directory: URL
    let startedAt: Date
    var roster = ParticipantRoster()
    var speaking = SpeakingTimeline()
    var participantCount = 0
    var speakingWritten = Date.distantPast
    var speakingUnwritten = false
  }
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
      let reading = muteReader.read()
      mirrorMicrophone(reading.state)
      deliver?(reading)
      done(reading.state)
    }
  }

  func setRoster(directory: URL, startedAt: Date) {
    queue.async { [self] in
      collection = Collection(directory: directory, startedAt: startedAt)
      lastMeetingRead = .distantPast
      lastRosterRead = .distantPast
    }
  }

  func clearRoster(_ done: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      if let collection { writeSpeaking(collection) }
      collection = nil
      done()
    }
  }

  private func tick() {
    let now = Date()
    if now.timeIntervalSince(lastStateRead) >= (mirrored == nil && collection == nil ? 2 : 0.4) {
      lastStateRead = now
      let reading = muteReader.read()
      mirrorMicrophone(reading.state)
      deliver?(reading)
      let seconds = Date().timeIntervalSince(now)
      if seconds >= 1 { AppLog.event("teams.slowRead", String(format: "mute=%.1fs", seconds)) }
    }
    guard var current = collection, now.timeIntervalSince(lastMeetingRead) >= 0.8 else { return }
    lastMeetingRead = now
    let snapshotStarted = Date()
    let snapshot = TeamsParticipantReader.snapshot()
    let snapshotSeconds = Date().timeIntervalSince(snapshotStarted)
    if snapshotSeconds >= 1 {
      AppLog.event("teams.slowRead", String(format: "participants=%.1fs", snapshotSeconds))
    }
    guard let snapshot else { return }
    if let speaker = snapshot.speaker {
      // The host clock times the capture tracks, so the helper can align these readings.
      current.speaking.observe(speaker, at: ProcessInfo.processInfo.systemUptime)
      current.speakingUnwritten = current.speakingUnwritten || speaker != nil
      if current.speakingUnwritten, now.timeIntervalSince(current.speakingWritten) >= 5 {
        writeSpeaking(current)
        current.speakingWritten = now
        current.speakingUnwritten = false
      }
    }
    if now.timeIntervalSince(lastRosterRead) >= 2, let sightings = snapshot.participants {
      lastRosterRead = now
      if current.roster.observe(sightings, at: now.timeIntervalSince(current.startedAt)) {
        try? JSONEncoder().encode(current.roster).write(
          to: current.directory.appendingPathComponent("participants.json"), options: .atomic)
        if let name = current.roster.localParticipant?.name { deliverLocalName?(name) }
        if current.roster.participants.count != current.participantCount {
          current.participantCount = current.roster.participants.count
          AppLog.event(
            "teams.participants",
            "count=\(current.participantCount); fullRoster=\(current.roster.sawFullRoster); local=\(current.roster.localParticipant != nil)"
          )
        }
      }
    }
    collection = current
  }

  private func writeSpeaking(_ collection: Collection) {
    guard !collection.speaking.intervals.isEmpty else { return }
    try? JSONEncoder().encode(collection.speaking).write(
      to: collection.directory.appendingPathComponent("speaking.json"), options: .atomic)
  }

  private func mirrorMicrophone(_ state: TeamsMuteState) {
    guard let muted = state.microphoneMuted else { return }
    mirrored?.setMicrophoneMuted(muted)
  }
}

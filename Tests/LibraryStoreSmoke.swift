import Foundation

extension Smoke {
  /// The first read of a protected folder can wait for a macOS privacy prompt. Launch must not
  /// wait with it: the main actor keeps answering status requests and recovery runs on its own
  /// once the read returns. Navigation waits for the initial scan without ignoring denied access.
  @MainActor
  static func testNonBlockingStartup(root: URL) async throws {
    let manager = FileManager.default
    let meetings = root.appendingPathComponent("meetings")
    let library = MeetingLibrary(root: meetings)
    library.trash = { _ in }
    try library.save(
      MeetingRecord(
        id: "20261105T110000Z", title: "Crashed", startedAt: Date(timeIntervalSince1970: 1_000),
        status: .recording))
    let prompt = DispatchSemaphore(value: 0)
    let store = LibraryStore(root: meetings, retryInterval: .milliseconds(20)) { root in
      LibraryReader(root: root) { url in
        prompt.wait()
        try LibraryReader.listFolder(url)
      }
    }
    let engine = MeetingEngine(library: library, teams: TeamsMonitor())
    var ready = 0
    store.onReady = { snapshot in
      ready += 1
      engine.recover(snapshot.recoverable)
    }
    let config = ConfigStore(file: root.appendingPathComponent("config.json"))
    config.load()
    var openedLinks: [MeetingLink] = []
    let commands = CommandCenter(
      engine: engine, config: config, teams: TeamsMonitor(),
      context: CommandCenter.Context(
        permissions: {
          PermissionSnapshot(microphone: true, systemAudio: true, accessibility: true)
        },
        requestingPermissions: { false }, updateInstalling: { false }, refreshPermissions: {},
        meetings: { await store.current().meetings },
        folderUnavailable: { store.unavailableReason },
        waitForFolderAccess: { try await store.waitForAccess() },
        openMeeting: { openedLinks.append($0) }))
    commands.events = EventLog(file: root.appendingPathComponent("events.jsonl"))

    let opened = Date()
    store.open()
    precondition(Date().timeIntervalSince(opened) < 0.5, "Opening the library must not wait")
    precondition(store.access == .checking)
    let status = await commands.status()
    precondition(status.startBlockedReason?.contains("Waiting for access") == true)
    precondition(status.attention.isEmpty && status.lastTranscriptId == nil)
    for command in [MeetingCommand.start(title: nil), .retry(id: nil), .delete(id: "latest")] {
      guard case .failure(let error) = await commands.perform(command, source: .socket) else {
        preconditionFailure("\(command) must wait for folder access")
      }
      precondition(error.message.contains("Waiting for access"), error.message)
    }
    guard
      case .success = await commands.perform(
        .updateSettings(SettingsChange(mirrorTeamsMute: false)), source: .socket)
    else { preconditionFailure("Settings do not need the meetings folder") }
    let link = MeetingLink(meetingID: "20261105T110000Z")
    var navigationFinished = false
    let navigation = Task {
      let response = await commands.handle(
        ControlRequest(command: "open_meeting", arguments: ["url": .string(link.string)]))
      navigationFinished = true
      return response
    }
    do {
      try await store.waitForAccess(timeout: .milliseconds(50))
      preconditionFailure("A stalled access probe must remain an error")
    } catch {
      precondition(error.localizedDescription.contains("Waiting for access"))
    }
    try await Task.sleep(for: .milliseconds(100))
    precondition(store.access == .checking && ready == 0 && engine.unfinished.isEmpty)

    precondition(!navigationFinished && openedLinks.isEmpty)
    prompt.signal()
    await MeetingSmoke.waitUntil { store.isReady }
    let navigated = await navigation.value
    precondition(navigated.ok && navigationFinished && openedLinks == [link])
    precondition(ready == 1)
    precondition(store.snapshot.meetings.map(\.id) == ["20261105T110000Z"])
    let recovered = try library.load("20261105T110000Z")
    precondition(recovered.status == .interrupted)
    precondition(commands.startBlockedReason == nil)

    let locked = root.appendingPathComponent("locked")
    try manager.createDirectory(at: locked, withIntermediateDirectories: true)
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let denied = LibraryStore(root: locked, retryInterval: .milliseconds(20))
    denied.open()
    await MeetingSmoke.waitUntil {
      if case .denied = denied.access { return true }
      return false
    }
    precondition(denied.unavailableReason?.contains("Files and Folders") == true)
    do {
      try await denied.waitForAccess()
      preconditionFailure("Navigation must not bypass denied access")
    } catch {
      precondition(error.localizedDescription.contains("Files and Folders"))
    }
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    await MeetingSmoke.waitUntil { denied.isReady }

    let missing = LibraryStore(root: root.appendingPathComponent("not-created-yet"))
    missing.open()
    await MeetingSmoke.waitUntil { missing.isReady }

    let earlier = root.appendingPathComponent("earlier")
    let earlierTranscripts = earlier.appendingPathComponent("transcripts")
    try manager.createDirectory(at: earlierTranscripts, withIntermediateDirectories: true)
    try "[00:00:01] Speaker 1: Hello.\n".write(
      to: earlierTranscripts.appendingPathComponent("2026-11-03 17.39 Weekly Sync.txt"),
      atomically: true, encoding: .utf8)
    let updated = LibraryStore(root: earlier, retryInterval: .milliseconds(20))
    var states: [MeetingsFolderAccess] = []
    updated.onChange = { states.append(updated.access) }
    updated.open()
    await MeetingSmoke.waitUntil { updated.isReady }
    precondition(
      states == [.checking, .loading(updating: true), .granted],
      "An update reports converting meetings, not waiting for access: \(states)")
    precondition(updated.snapshot.meetings.map(\.title) == ["Weekly Sync"])
    print("Launch never waits for the meetings folder; access is retried until granted: OK")
  }
}

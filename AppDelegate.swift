import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
  UNUserNotificationCenterDelegate
{
  private enum Phase { case idle, preparing, recording, transcribing, success, error }
  private enum RecordingStatus { case active, inactive, unknown }

  private let store: StateStore
  private var statusItem: NSStatusItem!
  private let menu = NSMenu()
  private var phase: Phase = .idle
  private var message: String?
  private var successUntil: Date?
  private var timer: Timer?
  private var work: Task<Void, Never>?
  private var launchedFluid = false
  private var teamsMirror: TeamsMuteMirror?
  private var mirrorWarning: String?
  private let teamsMuteDisabledKey = "teamsMuteDetectionDisabled"

  init(store: StateStore) {
    self.store = store
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppLog.event(
      "app.launch", "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown")")
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.menu = menu
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    Task {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      AppLog.event(
        "permissions",
        "notifications=\(settings.authorizationStatus.rawValue); alerts=\(settings.alertSetting.rawValue); accessibility=\(TeamsMuteReader.hasAccessibilityAccess)"
      )
    }
    updateIcon()
    let center = UNUserNotificationCenter.current()
    center.removeAllPendingNotificationRequests()
    center.getDeliveredNotifications { notifications in
      UNUserNotificationCenter.current().removeDeliveredNotifications(
        withIdentifiers: notifications.map(\.request.identifier).filter {
          $0 != "meeting-notes-error"
        })
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
    work = Task { await recover() }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if detectTeamsMute && !TeamsMuteReader.hasAccessibilityAccess {
      add("Grant Accessibility…", action: #selector(requestAccessibilityClicked), enabled: true)
      menu.addItem(.separator())
    }
    if phase == .recording {
      add(
        "Stop & Transcribe", action: #selector(stopClicked),
        enabled: store.state.session != nil && store.state.session?.recordedPath == nil)
    } else {
      add(
        "Start Recording", action: #selector(startClicked),
        enabled: store.state.session == nil && !isBusy)
    }
    let failedAudioAvailable =
      store.state.pendingAudio != nil || store.state.session?.recordedPath != nil
    if phase == .error && failedAudioAvailable {
      add("Retry Transcription", action: #selector(retryClicked), enabled: true)
    }
    menu.addItem(.separator())
    let hasTranscript =
      store.state.lastTranscript.map { FileManager.default.fileExists(atPath: $0) } ?? false
    add("Copy Last Transcript Path", action: #selector(copyPathClicked), enabled: hasTranscript)
    add("Show in Finder", action: #selector(showInFinderClicked), enabled: hasTranscript)
    menu.addItem(.separator())
    let detection = NSMenuItem(
      title: "Mirror Teams Mute", action: #selector(toggleTeamsMuteClicked), keyEquivalent: "")
    detection.target = self
    detection.state = detectTeamsMute ? .on : .off
    detection.isEnabled = store.state.session == nil && !isBusy
    menu.addItem(detection)
    let login = NSMenuItem(
      title: "Launch at Login", action: #selector(toggleLoginClicked), keyEquivalent: "")
    login.target = self
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    add("Quit", action: #selector(quitClicked), enabled: true)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    AppLog.event("notification.presented", notification.request.content.title)
    completionHandler([.banner, .list])
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppLog.event("app.quitRequested", "phase=\(phase)")
    if store.state.session != nil || phase == .transcribing {
      let alert = NSAlert()
      alert.messageText = "Quit Meeting Notes?"
      alert.informativeText =
        store.state.session?.recordedPath == nil && store.state.session != nil
        ? "OBS will keep recording. Teams mute mirroring stops until Meeting Notes is reopened."
        : "Transcription will stop. The MP3 will be kept for Retry Transcription."
      alert.addButton(withTitle: "Keep Open")
      alert.addButton(withTitle: "Quit")
      if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
    }
    work?.cancel()
    teamsMirror?.stop()
    AppLauncher.closeIfLaunched(AppLauncher.fluidID, launched: launchedFluid)
    return .terminateNow
  }

  @objc private func startClicked() { work = Task { await startRecording() } }
  @objc private func stopClicked() { work = Task { await stopRecording() } }
  @objc private func retryClicked() { work = Task { await retry() } }
  @objc private func quitClicked() { NSApp.terminate(nil) }

  @objc private func toggleTeamsMuteClicked() {
    guard store.state.session == nil && !isBusy else { return }
    UserDefaults.standard.set(detectTeamsMute, forKey: teamsMuteDisabledKey)
    setMirrorWarning(nil)
  }

  @objc private func requestAccessibilityClicked() {
    TeamsMuteReader.requestAccess()
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleLoginClicked() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch { presentError("Launch at Login: \(error.localizedDescription)") }
  }

  @objc private func copyPathClicked() {
    guard let path = store.state.lastTranscript else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }

  @objc private func showInFinderClicked() {
    guard let path = store.state.lastTranscript else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  private var isBusy: Bool { phase == .preparing || phase == .transcribing }
  private var detectTeamsMute: Bool { !UserDefaults.standard.bool(forKey: teamsMuteDisabledKey) }

  private func add(_ title: String, action: Selector, enabled: Bool) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    menu.addItem(item)
  }

  private func tick() {
    if phase == .success, let successUntil, Date() >= successUntil {
      setPhase(.idle)
      return
    }
    guard phase == .recording else { return }
    updateIcon()
  }

  private func setPhase(_ newPhase: Phase, message: String? = nil) {
    AppLog.event("phase", "\(phase) -> \(newPhase); \(message ?? "")")
    phase = newPhase
    self.message = message
    successUntil = newPhase == .success ? Date().addingTimeInterval(10) : nil
    if newPhase == .success || (newPhase == .recording && message == nil) {
      UNUserNotificationCenter.current().removeDeliveredNotifications(
        withIdentifiers: ["meeting-notes-error"])
    }
    updateIcon()
  }

  private func updateIcon() {
    guard let button = statusItem?.button else { return }
    let color: NSColor
    switch phase {
    case .idle: color = .labelColor
    case .preparing, .transcribing: color = .systemOrange
    case .recording:
      let wave = (1 + cos(ProcessInfo.processInfo.systemUptime * .pi)) / 2
      color = NSColor.systemRed.withAlphaComponent(0.75 + 0.25 * wave)
    case .success: color = .systemGreen
    case .error: color = .systemRed
    }
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Notes")?
      .withSymbolConfiguration(config)
    image?.isTemplate = false
    button.image = image
    button.toolTip = message ?? "Meeting Notes"
  }

  private func setMirrorWarning(_ warning: String?) {
    guard mirrorWarning != warning else { return }
    mirrorWarning = warning
    AppLog.event("teams.warning", warning ?? "cleared")
  }

  private func beginMirror(using client: OBSClient?) {
    let mirror = TeamsMuteMirror(client: client) { [weak self] warning in
      self?.setMirrorWarning(warning)
    }
    teamsMirror = mirror
    mirror.start()
  }

  private func notify(_ title: String, _ body: String) {
    guard title == "Meeting Notes error" else { return }
    AppLog.event("notification.request", "\(title): \(body)")
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    Task {
      let center = UNUserNotificationCenter.current()
      do {
        let allowed = try await center.requestAuthorization(options: [.alert])
        guard allowed else {
          AppLog.event("notification.denied")
          NSLog("Meeting Notes notifications are disabled in System Settings.")
          return
        }
        try await center.add(
          UNNotificationRequest(
            identifier: "meeting-notes-error", content: content, trigger: nil))
        AppLog.event("notification.scheduled", title)
      } catch {
        AppLog.event("notification.failed", error.localizedDescription)
        NSLog("Meeting Notes notification delivery failed: %@", error.localizedDescription)
      }
    }
  }

  private func presentError(_ text: String) {
    AppLog.event("error", text)
    NSLog("Meeting Notes error: %@", text)
    setPhase(.error, message: text)
    notify("Meeting Notes error", text)
  }

  private func obsWithRetries() async throws -> OBSClient {
    var last: Error = MeetingError("OBS did not become ready.")
    for _ in 0..<20 {
      do {
        let client = try await OBSClient.connect()
        do {
          _ = try await client.isRecording()
          _ = try await client.isStreaming()
          return client
        } catch {
          client.close()
          throw error
        }
      } catch {
        last = error
        try await Task.sleep(nanoseconds: 400_000_000)
      }
    }
    throw last
  }

  private func waitForRecording(using initial: OBSClient?) async -> RecordingStatus {
    var client = initial
    var ownsClient = false
    var sawInactive = false
    defer { if ownsClient { client?.close() } }
    for attempt in 0..<12 {
      if client == nil {
        client = try? await OBSClient.connect()
        ownsClient = client != nil
      }
      if let connection = client {
        do {
          if try await connection.isRecording() { return .active }
          sawInactive = true
        } catch {
          if ownsClient { connection.close() }
          client = nil
          ownsClient = false
        }
      }
      if attempt < 11 { try? await Task.sleep(nanoseconds: 250_000_000) }
    }
    return sawInactive ? .inactive : .unknown
  }

  private func closeOBSIfIdle(launched: Bool) async {
    guard launched, AppLauncher.isRunning(AppLauncher.obsID) else { return }
    guard let client = try? await OBSClient.connect() else { return }
    defer { client.close() }
    guard let recording = try? await client.isRecording(), !recording,
      let streaming = try? await client.isStreaming(), !streaming
    else { return }
    AppLauncher.closeIfLaunched(AppLauncher.obsID, launched: true)
  }

  private func fluidWithRetries() async throws -> FluidVoiceClient {
    let client = FluidVoiceClient()
    var last: Error = MeetingError("FluidVoice did not become ready.")
    for _ in 0..<20 {
      do {
        try await client.health()
        return client
      } catch {
        last = error
        try await Task.sleep(nanoseconds: 400_000_000)
      }
    }
    throw last
  }

  private func startRecording() async {
    guard store.state.session == nil, !isBusy else { return }
    setPhase(.preparing, message: "Opening OBS…")
    var launched = false
    var obs: OBSClient?
    var startRequested = false
    var recordingStatus: RecordingStatus?
    do {
      try MeetingFiles.ensureDirectories()
      launched = try await AppLauncher.openIfNeeded(
        bundleID: AppLauncher.obsID, path: "/Applications/OBS.app", hidden: true)
      obs = try await obsWithRetries()
      AppLauncher.hide(AppLauncher.obsID)
      guard let connected = obs else { throw MeetingError("OBS is unavailable.") }
      let alreadyRecording = try await connected.isRecording()
      let alreadyStreaming = try await connected.isStreaming()
      if alreadyRecording || alreadyStreaming {
        throw MeetingError(
          "OBS is already recording or streaming. That session was left untouched.")
      }
      setPhase(.preparing, message: "Checking audio setup…")
      let teamsState = detectTeamsMute ? TeamsMuteReader.read() : .unmuted
      try await connected.repairAudioSetup(microphoneMuted: teamsState.obsMicrophoneMuted)
      let startedAt = Date()
      let session = MeetingSession(
        startedAt: startedAt,
        stem: MeetingFiles.stem(for: startedAt), launchedOBS: launched)
      try store.update { $0.session = session }
      startRequested = true
      var startError: Error?
      do { _ = try await connected.request("StartRecord") } catch { startError = error }
      recordingStatus = await waitForRecording(using: connected)
      guard recordingStatus == .active else {
        throw startError ?? MeetingError("OBS did not confirm that recording started.")
      }
      AppLauncher.hide(AppLauncher.obsID)
      setPhase(.recording)
      if detectTeamsMute {
        if case .unavailable(let reason) = teamsState {
          setMirrorWarning("Teams mute unavailable: \(reason.message) OBS mic stays on.")
        }
        beginMirror(using: nil)
      }
    } catch {
      if startRequested, store.state.session != nil {
        let status: RecordingStatus
        if let recordingStatus {
          status = recordingStatus
        } else {
          status = await waitForRecording(using: obs)
        }
        switch status {
        case .active:
          AppLauncher.hide(AppLauncher.obsID)
          setPhase(.recording)
          if detectTeamsMute { beginMirror(using: nil) }
        case .unknown:
          setPhase(.recording, message: "OBS recording status unknown; check OBS.")
          if detectTeamsMute { beginMirror(using: nil) }
          notify("Meeting Notes error", "Cannot verify OBS recording. OBS was left running.")
        case .inactive:
          try? store.update { $0.session = nil }
          presentError(error.localizedDescription)
        }
      } else {
        try? store.update { $0.session = nil }
        await closeOBSIfIdle(launched: launched)
        presentError(error.localizedDescription)
      }
    }
    obs?.close()
    work = nil
  }

  private func stopRecording() async {
    guard var session = store.state.session, session.recordedPath == nil, phase == .recording else {
      return
    }
    teamsMirror?.stop()
    teamsMirror = nil
    setPhase(.preparing, message: "Stopping OBS…")
    var obs: OBSClient?
    do {
      let connected = try await obsWithRetries()
      obs = connected
      guard try await connected.isRecording() else {
        throw MeetingError("OBS is no longer recording. Check Movies for the MP3.")
      }
      let result = try await connected.request("StopRecord")
      guard let path = result["outputPath"] as? String, !path.isEmpty else {
        throw MeetingError("OBS did not return the recording path.")
      }
      session.recordedPath = path
      AppLog.event("obs.recordedPath", path)
      try store.update { $0.session = session }
      if detectTeamsMute {
        _ = try? await connected.request(
          "SetInputMute", ["inputName": "Mic/Aux", "inputMuted": false])
      }
      connected.close()
      obs = nil
      try await finishRecording(session)
    } catch {
      if let connection = obs, let active = try? await connection.isRecording(),
        store.state.session?.recordedPath == nil
      {
        if active {
          setPhase(.recording, message: "Stop & Transcribe failed: \(error.localizedDescription)")
          if detectTeamsMute {
            beginMirror(using: connection)
            obs = nil
          }
          notify("Meeting Notes error", error.localizedDescription)
        } else {
          try? store.update { $0.session = nil }
          await closeOBSIfIdle(launched: session.launchedOBS)
          presentError(error.localizedDescription)
        }
      } else {
        if store.state.session?.recordedPath == nil {
          let warning = "Cannot verify OBS recording: \(error.localizedDescription)"
          setPhase(.recording, message: warning)
          notify("Meeting Notes error", warning)
          if detectTeamsMute { beginMirror(using: nil) }
        } else {
          presentError(error.localizedDescription)
        }
      }
    }
    obs?.close()
    work = nil
  }

  private func finishRecording(_ session: MeetingSession) async throws {
    guard let recordedPath = session.recordedPath else {
      throw MeetingError("Recording path is missing.")
    }
    if AppLauncher.isRunning(AppLauncher.obsID) {
      let client = try await obsWithRetries()
      defer { client.close() }
      try await OBSClient.waitUntilStopped { try await client.isRecording() }
    }
    try MeetingFiles.ensureDirectories()
    let source = URL(fileURLWithPath: recordedPath)
    let destination = MeetingFiles.audio(for: session.stem)
    if FileManager.default.fileExists(atPath: source.path)
      || !FileManager.default.fileExists(atPath: destination.path)
    {
      try await MeetingFiles.waitForMP3(source)
      _ = try AudioChunker(file: source)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw MeetingError(
          "An audio file with this timestamp already exists. Nothing was overwritten.")
      }
      try FileManager.default.moveItem(at: source, to: destination)
      AppLog.event("mp3.moved", "\(source.path) -> \(destination.path)")
    }
    try store.update { state in
      state.session = nil
      state.pendingAudio = destination.path
    }
    await closeOBSIfIdle(launched: session.launchedOBS)
    await transcribe(destination)
  }

  private func retry() async {
    AppLog.event("transcription.retry")
    guard !isBusy else { return }
    if let session = store.state.session, session.recordedPath != nil {
      setPhase(.preparing, message: "Recovering MP3…")
      do { try await finishRecording(session) } catch { presentError(error.localizedDescription) }
    } else if let path = store.state.pendingAudio {
      await transcribe(URL(fileURLWithPath: path))
    }
    work = nil
  }

  private func transcribe(_ audio: URL) async {
    setPhase(.transcribing)
    do {
      guard FileManager.default.fileExists(atPath: audio.path) else {
        throw MeetingError("The MP3 is missing.")
      }
      launchedFluid = try await AppLauncher.openIfNeeded(
        bundleID: AppLauncher.fluidID,
        path: "/Applications/FluidVoice.app")
      let client = try await fluidWithRetries()
      let chunker = try AudioChunker(file: audio)
      AppLog.event("transcription.begin", "\(audio.path); chunks=\(chunker.chunkCount)")
      let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-notes-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: temporary) }
      var parts: [String] = []
      for index in 0..<chunker.chunkCount {
        try Task.checkCancellation()
        let chunk = try chunker.chunk(at: index, original: audio, in: temporary)
        AppLog.event("transcription.chunk", "\(index + 1)/\(chunker.chunkCount)")
        parts.append(try await client.transcribe(file: chunk))
        AppLog.event("transcription.chunkComplete", "\(index + 1)/\(chunker.chunkCount)")
        if chunk != audio { try FileManager.default.removeItem(at: chunk) }
      }
      let text = parts.joined(separator: "\n\n") + "\n"
      let destination = MeetingFiles.transcript(
        for: audio.deletingPathExtension().lastPathComponent)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw MeetingError("The transcript already exists. Nothing was overwritten.")
      }
      let staging = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(UUID().uuidString).partial")
      defer { try? FileManager.default.removeItem(at: staging) }
      try Data(text.utf8).write(to: staging, options: .atomic)
      try FileManager.default.moveItem(at: staging, to: destination)
      AppLog.event("transcription.saved", destination.path)
      try store.update { state in
        state.pendingAudio = nil
        state.lastTranscript = destination.path
      }
      setPhase(.success)
    } catch {
      if !Task.isCancelled { presentError(error.localizedDescription) }
    }
    AppLauncher.closeIfLaunched(AppLauncher.fluidID, launched: launchedFluid)
    launchedFluid = false
  }

  private func recover() async {
    AppLog.event(
      "app.recover",
      "session=\(store.state.session != nil); pendingAudio=\(store.state.pendingAudio != nil)")
    if let session = store.state.session {
      if session.recordedPath != nil {
        presentError("Previous MP3 needs processing. Choose Retry Transcription.")
      } else if AppLauncher.isRunning(AppLauncher.obsID) {
        var connection: OBSClient?
        do {
          let obs = try await obsWithRetries()
          connection = obs
          let active = try await obs.isRecording()
          if active {
            setPhase(.recording)
            if detectTeamsMute {
              let state = TeamsMuteReader.read()
              _ = try await obs.request(
                "SetInputMute",
                ["inputName": "Mic/Aux", "inputMuted": state.obsMicrophoneMuted])
              beginMirror(using: obs)
              connection = nil
              if case .unavailable(let reason) = state {
                setMirrorWarning("Teams mute unavailable: \(reason.message) OBS mic stays on.")
              }
            } else {
              connection = nil
              obs.close()
            }
          } else {
            connection = nil
            obs.close()
            try? store.update { $0.session = nil }
            presentError("Previous OBS recording ended outside Meeting Notes. Check Movies.")
          }
        } catch {
          connection?.close()
          setPhase(.recording)
          setMirrorWarning("Cannot verify OBS mic: \(error.localizedDescription)")
          if detectTeamsMute { beginMirror(using: nil) }
        }
      } else {
        try? store.update { $0.session = nil }
        presentError("Previous OBS recording is no longer running. Check Movies.")
      }
    } else if let pending = store.state.pendingAudio {
      let transcript = MeetingFiles.transcript(
        for: URL(fileURLWithPath: pending)
          .deletingPathExtension().lastPathComponent)
      if FileManager.default.fileExists(atPath: transcript.path) {
        try? store.update { state in
          state.pendingAudio = nil
          state.lastTranscript = transcript.path
        }
      } else {
        presentError("Last transcription needs Retry.")
      }
    }
    work = nil
  }
}

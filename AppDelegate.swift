import AppKit
import ScreenCaptureKit
import ServiceManagement
import UserNotifications

@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
  UNUserNotificationCenterDelegate
{
  private enum Phase { case idle, preparing, recording, transcribing, success, error }
  private let store: StateStore
  private let menu = NSMenu()
  private let teamsStatusItem = NSMenuItem(
    title: "Detecting Teams meeting…", action: nil, keyEquivalent: "")
  private var statusItem: NSStatusItem!
  private var phase: Phase = .idle
  private var message: String?
  private var successUntil: Date?
  private var timer: Timer?
  private var permissionTimer: Timer?
  private var permissions = PermissionSnapshot.read()
  private var screenAccessRejected = false
  private var refreshingPermissions = false
  private var requestingPermissions = false
  private var screenPermissionContinuation = ScreenPermissionContinuation()
  private var work: Task<Void, Never>?
  private var recorder: NativeRecorder?
  private let teamsMonitor = TeamsMonitor()
  private var autoRecord = TeamsAutoRecordPolicy()
  private let transcriber = NativeTranscriber()
  private var detectTeamsMute: Bool {
    !UserDefaults.standard.bool(forKey: "teamsMuteDetectionDisabled")
  }
  private var autoRecordTeamsMeetings: Bool {
    UserDefaults.standard.bool(forKey: "autoRecordTeamsMeetings")
  }
  private var isBusy: Bool { phase == .preparing || phase == .transcribing }
  private var canStartRecording: Bool {
    permissions.recordingGranted && !requestingPermissions && !isBusy && recorder == nil
      && store.state.session == nil
  }
  private lazy var permissionWarningImage: NSImage = {
    let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
      NSColor.systemOrange.setFill()
      NSBezierPath(ovalIn: rect).fill()
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 10),
        .foregroundColor: NSColor.black,
      ]
      let mark = "!" as NSString
      let size = mark.size(withAttributes: attrs)
      mark.draw(
        at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
        withAttributes: attrs)
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "Meeting Notes: Permissions required"
    return image
  }()

  init(store: StateStore) {
    self.store = store
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppLog.event(
      "app.launch", "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown")")
    AppLog.event(
      "permissions.initial", "missing=\(permissions.missing.map(\.rawValue).joined(separator: ","))"
    )
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.menu = menu
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert]) { _, _ in }
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
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refreshPermissions() }
    }
    if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    teamsMonitor.onStateChanged = { [weak self] in
      self?.updateTeamsStatusItem()
      self?.updateIcon()
    }
    teamsMonitor.onReading = { [weak self] in self?.evaluateAutoRecord() }
    if store.state.session != nil || store.state.pendingAudio != nil {
      presentError(
        "An interrupted recording or transcript needs processing. Choose Retry Transcription.")
    } else {
      setPhase(.idle)
      do { try enforceRetention() } catch { presentError(error.localizedDescription) }
    }
    updateTeamsMonitor()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    Task { await refreshPermissions() }
    menu.removeAllItems()
    teamsStatusItem.isEnabled = false
    updateTeamsStatusItem()
    menu.addItem(teamsStatusItem)
    if phase == .recording {
      add("Stop & Transcribe", action: #selector(stopClicked))
    } else if !permissions.recordingGranted {
      add(
        "Grant Permissions…", action: #selector(grantPermissionsClicked),
        enabled: !requestingPermissions)
    } else {
      add("Start Recording", action: #selector(startClicked), enabled: canStartRecording)
    }
    if phase == .error && (store.state.pendingAudio != nil || store.state.session != nil) {
      add("Retry Transcription", action: #selector(retryClicked))
    }
    menu.addItem(.separator())
    let hasTranscript =
      store.state.lastTranscript.map { FileManager.default.fileExists(atPath: $0) } ?? false
    add("Copy Last Transcript Path", action: #selector(copyPathClicked), enabled: hasTranscript)
    add("Show in Finder", action: #selector(showInFinderClicked), enabled: hasTranscript)
    menu.addItem(.separator())
    let mirror = add(
      "Mirror Teams Mute", action: #selector(toggleTeamsMuteClicked),
      enabled: !isBusy && recorder == nil)
    mirror.state = detectTeamsMute ? .on : .off
    let autoRecordItem = add(
      "Auto-Record Teams Meetings", action: #selector(toggleAutoRecordClicked))
    autoRecordItem.state = autoRecordTeamsMeetings ? .on : .off
    let login = add("Launch at Login", action: #selector(toggleLoginClicked))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    add("Quit", action: #selector(quitClicked))
  }

  @discardableResult
  private func add(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    menu.addItem(item)
    return item
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if recorder != nil || isBusy {
      let alert = NSAlert()
      alert.messageText = "Quit Meeting Notes?"
      alert.informativeText =
        "Recording and transcription will stop. Saved audio will be kept for Retry Transcription when you reopen the app."
      alert.addButton(withTitle: "Keep Open")
      alert.addButton(withTitle: "Quit")
      guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    }
    work?.cancel()
    transcriber.cancel()
    teamsMonitor.stop()
    if let recorder {
      Task {
        try? await recorder.stop()
        NSApp.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
    return .terminateNow
  }

  @objc private func startClicked() { work = Task { await startRecording(automatically: false) } }
  @objc private func stopClicked() { work = Task { await stopRecording() } }
  @objc private func retryClicked() { work = Task { await retry() } }
  @objc private func quitClicked() { NSApp.terminate(nil) }
  @objc private func grantPermissionsClicked() {
    guard !requestingPermissions else { return }
    requestingPermissions = true
    screenPermissionContinuation.waitingForAccessibility = false
    Task {
      defer { requestingPermissions = false }
      AppLog.event("permissions.requested")
      let result = await PermissionAccess.requestMissing()
      screenPermissionContinuation.waitingForAccessibility = result == .waitingForAccessibility
      await refreshPermissions()
    }
  }
  @objc private func toggleTeamsMuteClicked() {
    UserDefaults.standard.set(detectTeamsMute, forKey: "teamsMuteDetectionDisabled")
  }
  @objc private func toggleAutoRecordClicked() {
    let enabled = !autoRecordTeamsMeetings
    UserDefaults.standard.set(enabled, forKey: "autoRecordTeamsMeetings")
    AppLog.event("autoRecord.toggled", enabled ? "on" : "off")
    autoRecord = TeamsAutoRecordPolicy()
    updateTeamsMonitor()
  }
  @objc private func toggleLoginClicked() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch { presentError(error.localizedDescription) }
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

  private func tick() {
    if phase == .success, let successUntil, Date() >= successUntil {
      setPhase(.idle)
    } else if phase == .recording {
      updateIcon()
    }
  }
  private func refreshPermissions() async {
    guard !refreshingPermissions else { return }
    refreshingPermissions = true
    defer { refreshingPermissions = false }
    var current = PermissionSnapshot.read()
    if screenAccessRejected && current.screenRecording {
      do {
        _ = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        screenAccessRejected = false
      } catch {
        current.screenRecording = false
      }
    }
    if current != permissions {
      permissions = current
      AppLog.event(
        "permissions.changed", "missing=\(current.missing.map(\.rawValue).joined(separator: ","))")
      updateTeamsStatusItem()
      updateIcon()
    }
    if !requestingPermissions && screenPermissionContinuation.consumeRequest(for: current) {
      AppLog.event("permissions.continuingAfterAccessibility")
      grantPermissionsClicked()
    }
  }
  private func setPhase(_ value: Phase, message: String? = nil) {
    AppLog.event("phase", "\(phase) -> \(value); \(message ?? "")")
    phase = value
    updateTeamsStatusItem()
    self.message = message
    successUntil = value == .success ? Date().addingTimeInterval(10) : nil
    if value == .success || value == .recording {
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
        "meeting-notes-error"
      ])
    }
    updateIcon()
  }
  private func updateTeamsMonitor() {
    if autoRecordTeamsMeetings || teamsMonitor.mirroredRecorder != nil {
      teamsMonitor.start()
    } else {
      teamsMonitor.stop()
    }
  }
  private func evaluateAutoRecord() {
    guard autoRecordTeamsMeetings, let state = teamsMonitor.currentState else { return }
    switch autoRecord.observe(
      state.meetingPresence, at: Date(), isRecording: phase == .recording,
      canStart: canStartRecording)
    {
    case .start:
      AppLog.event("autoRecord.start")
      work = Task { await startRecording(automatically: true) }
    case .stop:
      AppLog.event("autoRecord.stop")
      work = Task { await stopRecording() }
    case nil: break
    }
  }
  private func updateTeamsStatusItem() {
    teamsStatusItem.isHidden = phase != .recording || teamsMonitor.mirroredRecorder == nil
    switch teamsMonitor.currentState {
    case .some(.muted): teamsStatusItem.title = "Muted in Teams"
    case .some(.unmuted): teamsStatusItem.title = "Not muted in Teams"
    case .some(.unavailable(.noMeeting)), .some(.unavailable(.teamsClosed)):
      teamsStatusItem.title = "No Teams meeting detected"
    case .some(.unavailable(_)): teamsStatusItem.title = "Teams mute status unavailable"
    case .none: teamsStatusItem.title = "Detecting Teams meeting…"
    }
  }
  private func updateIcon() {
    guard let button = statusItem?.button else { return }
    if !permissions.recordingGranted {
      button.image = permissionWarningImage
      button.toolTip =
        "Grant Permissions: \(permissions.missing.map(\.title).joined(separator: ", "))"
      return
    }
    let color: NSColor
    switch phase {
    case .idle: color = .labelColor
    case .preparing, .transcribing: color = .systemOrange
    case .recording:
      color = NSColor.systemRed.withAlphaComponent(
        0.75 + 0.25 * (1 + cos(ProcessInfo.processInfo.systemUptime * .pi)) / 2)
    case .success: color = .systemGreen
    case .error: color = .systemRed
    }
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold).applying(
      NSImage.SymbolConfiguration(paletteColors: [color]))
    let teamsMuted =
      phase == .recording && teamsMonitor.mirroredRecorder != nil
      && teamsMonitor.currentState == .muted
    let symbolName: String
    let accessibilityDescription: String
    if phase == .error {
      symbolName = "exclamationmark.circle.fill"
      accessibilityDescription = "Meeting Notes: Error"
    } else if teamsMuted {
      symbolName = "mic.slash.fill"
      accessibilityDescription = "Meeting Notes: Muted in Teams"
    } else {
      symbolName = "waveform"
      accessibilityDescription = "Meeting Notes"
    }
    let image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: accessibilityDescription)?
      .withSymbolConfiguration(config)
    image?.isTemplate = false
    button.image = image
    button.toolTip = teamsMuted ? "Meeting Notes: Muted in Teams" : message ?? "Meeting Notes"
  }
  private func presentError(_ text: String) {
    AppLog.event("error", text)
    setPhase(.error, message: text)
    let content = UNMutableNotificationContent()
    content.title = "Meeting Notes error"
    content.body = text
    Task {
      do {
        try await UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: "meeting-notes-error", content: content, trigger: nil))
      } catch { AppLog.event("notification.failed", error.localizedDescription) }
    }
  }

  private func startRecording(automatically: Bool) async {
    guard !isBusy, recorder == nil, store.state.session == nil else { return }
    await refreshPermissions()
    guard permissions.recordingGranted, !isBusy, recorder == nil, store.state.session == nil
    else { return }
    setPhase(.preparing)
    do {
      try MeetingFiles.ensureDirectories()
      try enforceRetention()
      let now = Date()
      let session = MeetingSession(startedAt: now, stem: MeetingFiles.stem(for: now))
      try store.update { $0.session = session }
      let capture = NativeRecorder(directory: MeetingFiles.capture(for: session.stem))
      recorder = capture
      capture.onFailure = { [weak self] error in
        Task { @MainActor in
          guard let self, self.phase == .recording else { return }
          self.work = Task { await self.stopRecording(captureError: error) }
        }
      }
      if detectTeamsMute {
        teamsMonitor.mirroredRecorder = capture
        updateTeamsMonitor()
      }
      try await capture.start()
      try Task.checkCancellation()
      if store.state.pendingAudio != nil {
        try store.update { $0.pendingAudio = nil }
      }
      autoRecord.recordingStarted(automatically: automatically)
      setPhase(.recording)
    } catch {
      autoRecord.recordingEnded()
      teamsMonitor.mirroredRecorder = nil
      updateTeamsMonitor()
      try? await recorder?.stop()
      recorder = nil
      if let session = store.state.session,
        !FileManager.default.fileExists(
          atPath: MeetingFiles.capture(for: session.stem).appendingPathComponent("capture.json")
            .path)
      {
        try? store.update { $0.session = nil }
      }
      handleCaptureError(error)
    }
    work = nil
  }

  private func stopRecording(captureError: Error? = nil) async {
    guard let capture = recorder, let session = store.state.session else { return }
    autoRecord.recordingEnded()
    setPhase(.preparing)
    teamsMonitor.mirroredRecorder = nil
    updateTeamsMonitor()
    var failure = captureError
    do { try await capture.stop() } catch { failure = failure ?? error }
    recorder = nil
    if let failure {
      handleCaptureError(failure)
    } else {
      do { try await finishRecording(session) } catch { presentError(error.localizedDescription) }
    }
    work = nil
  }

  private func handleCaptureError(_ error: Error) {
    guard let permission = PermissionAccess.deniedPermission(for: error) else {
      presentError(error.localizedDescription)
      return
    }
    switch permission {
    case .microphone: permissions.microphone = false
    case .screenRecording:
      screenAccessRejected = true
      permissions.screenRecording = false
    case .accessibility: permissions.accessibility = false
    }
    AppLog.event("permissions.captureBlocked", permission.rawValue)
    if let session = store.state.session,
      !FileManager.default.fileExists(
        atPath: MeetingFiles.capture(for: session.stem).appendingPathComponent("capture.json").path)
    {
      try? store.update { $0.session = nil }
    }
    setPhase(store.state.session == nil ? .idle : .error)
  }

  private func finishRecording(_ session: MeetingSession) async throws {
    let destination = MeetingFiles.audio(for: session.stem)
    let directory = MeetingFiles.capture(for: session.stem)
    if !FileManager.default.fileExists(atPath: destination.path) {
      guard
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("capture.json").path)
      else {
        try store.update { $0.session = nil }
        throw MeetingError(
          "No audio was captured. Check recording permissions and start a new recording.")
      }
      let partial = directory.appendingPathComponent("mixed.m4a")
      if FileManager.default.fileExists(atPath: partial.path) {
        try FileManager.default.removeItem(at: partial)
      }
      let mix = Task.detached { try NativeRecorder.mix(directory: directory, destination: partial) }
      try await withTaskCancellationHandler(
        operation: { try await mix.value }, onCancel: { mix.cancel() })
      try Task.checkCancellation()
      try FileManager.default.moveItem(at: partial, to: destination)
    }
    try store.update {
      $0.session = nil
      $0.pendingAudio = destination.path
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    AppLog.event("capture.saved", destination.path)
    try enforceRetention()
    await transcribe(destination)
  }

  private func retry() async {
    guard !isBusy else { return }
    AppLog.event("transcription.retry")
    if let session = store.state.session {
      setPhase(.preparing)
      do { try await finishRecording(session) } catch { presentError(error.localizedDescription) }
    } else if let path = store.state.pendingAudio {
      await transcribe(URL(fileURLWithPath: path))
    }
    work = nil
  }

  private func transcribe(_ audio: URL) async {
    setPhase(.transcribing)
    do {
      let destination = MeetingFiles.transcript(
        for: audio.deletingPathExtension().lastPathComponent)
      if !FileManager.default.fileExists(atPath: destination.path) {
        AppLog.event("transcription.begin", "\(audio.path); model=parakeet-tdt-v3; speakers=auto")
        let text = try await transcriber.transcribe(file: audio)
        try Task.checkCancellation()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
          ".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Data(text.utf8).write(to: staging, options: .atomic)
        try FileManager.default.moveItem(at: staging, to: destination)
        AppLog.event("transcription.saved", destination.path)
      }
      try store.update {
        $0.pendingAudio = nil
        $0.lastTranscript = destination.path
      }
      try enforceRetention()
      setPhase(.success)
    } catch is NoSpeechDetected where isShortRecording(audio) {
      discardSilentRecording(audio)
    } catch { if !Task.isCancelled { presentError(error.localizedDescription) } }
  }

  private func isShortRecording(_ audio: URL) -> Bool {
    guard let duration = try? NativeTranscriber.duration(of: audio) else { return false }
    return duration < 60
  }

  private func discardSilentRecording(_ audio: URL) {
    AppLog.event("transcription.discarded", "\(audio.path); no speech in recording under 1 minute")
    do {
      try store.update { $0.pendingAudio = nil }
      try FileManager.default.removeItem(at: audio)
      setPhase(.idle)
    } catch { presentError(error.localizedDescription) }
  }

  private func enforceRetention() throws {
    let protected = store.state.pendingAudio.map {
      URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
    }
    try RecordingRetention.enforce(root: MeetingFiles.root, protectedStem: protected)
    if let last = store.state.lastTranscript, !FileManager.default.fileExists(atPath: last) {
      try store.update { $0.lastTranscript = nil }
    }
  }
}

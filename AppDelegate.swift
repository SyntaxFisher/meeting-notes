import AppKit
import ServiceManagement

/// Wires the windows, the menu bar item, sounds, the URL scheme, the control
/// socket and the event log to `MeetingEngine` through `CommandCenter`. Meeting state lives in the
/// meeting records; this class only mirrors it into `AppModel` for the UI.
@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate {
  private static let detectedTeamsNameKey = "detectedTeamsName"

  /// The running app's delegate, for App Intents that execute inside the app process.
  private(set) static weak var current: MeetingAppDelegate?

  private let model = AppModel()
  private let sounds = MeetingSounds()
  private let paths = AutomationPaths.standard
  private let configStore = ConfigStore(file: AutomationPaths.standard.configFile)
  private let teamsMonitor = TeamsMonitor()
  private(set) var engine: MeetingEngine!
  private(set) var libraryStore: LibraryStore!
  private(set) var commands: CommandCenter!
  private var statusItem: NSStatusItem!
  private var panel: StatusPanelController!
  private lazy var libraryWindow = LibraryWindowController(model: LibraryModel(app: model))
  private lazy var settings: SettingsWindowController = {
    let controller = SettingsWindowController(model: model)
    controller.onVisibilityChanged = { [weak self] visible in
      if visible { self?.refreshModel() }
    }
    controller.onAgentsVisibilityChanged = { [weak self] visible in
      self?.agentsVisibilityChanged("settings", visible)
    }
    return controller
  }()
  private lazy var onboarding: OnboardingWindowController = {
    let controller = OnboardingWindowController(model: model)
    controller.onAgentsVisibilityChanged = { [weak self] visible in
      self?.agentsVisibilityChanged("onboarding", visible)
    }
    return controller
  }()
  private let appUpdater = AppUpdater()
  private var controlServer: ControlServer?
  private var problem: AppProblem?
  private var announcedStatus = ""
  private var timer: Timer?
  private var permissionTimer: Timer?
  private var permissionTicks = 0
  private var permissions = PermissionSnapshot.read()
  private var captureRetry = CaptureRetryPolicy()
  private var refreshingPermissions = false
  private var requestingPermissions = false
  private var autoRecord = TeamsAutoRecordPolicy()
  /// URLs that launched the app wait until it has finished launching and loaded its settings.
  private var launchURLs: [URL]? = []
  /// A meeting link that waits until the meetings folder has been read.
  private var pendingLink: MeetingLink?
  private var agentsCheckedAt = Date.distantPast
  private var agentCheck: Task<Void, Never>?
  private var agentPolling: Task<Void, Never>?
  /// The windows that currently show the agents' rows.
  private var agentsShownIn: Set<String> = []
  /// Agents with a connect or remove in progress; their state comes from that action.
  private var agentActions: Set<String> = []
  /// Changes whenever an agent action starts or ends, so a check that overlapped it is dropped.
  private var agentActionRevision = 0

  private var config: AppConfig { configStore.config }
  private var updateIsBusy: Bool {
    engine.isBusy || requestingPermissions || onboarding.isVisible
      || (config.autoRecordTeamsMeetings && autoRecord.waitingForMeetingEnd)
  }
  private var detectedTeamsName: String? {
    UserDefaults.standard.string(forKey: Self.detectedTeamsNameKey)
  }
  private lazy var permissionWarningImage = Self.alertImage(
    fill: .systemOrange, mark: .black, description: "Meeting Notes: Setup required")
  private lazy var errorImage = Self.alertImage(
    fill: .systemRed, mark: .black, description: "Meeting Notes: Needs attention")

  private static func alertImage(fill: NSColor, mark: NSColor, description: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
      fill.setFill()
      NSBezierPath(ovalIn: rect).fill()
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 10),
        .foregroundColor: mark,
      ]
      let exclamation = "!" as NSString
      let size = exclamation.size(withAttributes: attrs)
      exclamation.draw(
        at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
        withAttributes: attrs)
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = description
    return image
  }

  // MARK: Launch

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.current = self
    AppLog.event(
      "app.launch", "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown")")
    AppLog.event(
      "permissions.initial", "missing=\(permissions.missing.map(\.rawValue).joined(separator: ","))"
    )
    installCommandLineShim()
    configStore.load()
    MeetingFiles.root = config.meetingsRootURL
    libraryStore = LibraryStore(root: config.meetingsRootURL)
    engine = MeetingEngine(
      library: MeetingLibrary(root: config.meetingsRootURL), teams: teamsMonitor)
    engine.config = { [weak self] in self?.config ?? AppConfig() }
    engine.onRetention = { [weak self] protected in
      guard let self else { return }
      self.libraryStore.enforceRetention(
        protected: protected, audioBudget: self.config.retention.audioBytes)
    }
    engine.localSpeakerName = { [weak self] roster in
      TranscriptDocument.localSpeakerName(
        configured: self?.config.localSpeakerName,
        teamsName: roster?.localParticipant?.name ?? self?.detectedTeamsName)
    }
    engine.onChange = { [weak self] in self?.engineChanged() }
    engine.onEvent = { [weak self] event, record, details in
      self?.lifecycle(event, record, details)
    }
    engine.onPermissionDenied = { [weak self] permission, error in
      self?.captureBlocked(permission, error: error)
    }
    commands = CommandCenter(
      engine: engine, config: configStore, teams: teamsMonitor,
      context: CommandCenter.Context(
        permissions: { [weak self] in self?.permissions ?? PermissionSnapshot.read() },
        requestingPermissions: { [weak self] in self?.requestingPermissions ?? false },
        updateInstalling: { [weak self] in
          self?.appUpdater.installation.installationStarted ?? false
        },
        refreshPermissions: { [weak self] in await self?.refreshPermissions() },
        meetings: { [weak self] in await self?.libraryStore.current().meetings ?? [] },
        folderUnavailable: { [weak self] in self?.libraryStore.unavailableReason },
        waitForFolderAccess: { [weak self] in
          guard let self else { throw MeetingError("Meeting Notes is shutting down.") }
          try await self.libraryStore.waitForAccess()
        },
        openMeeting: { [weak self] link in
          guard let self else { throw MeetingError("Meeting Notes is shutting down.") }
          _ = await self.libraryStore.current()
          self.libraryWindow.show(link)
        }))
    libraryStore.onReady = { [weak self] snapshot in
      guard let self else { return }
      self.engine.recover(snapshot.recoverable)
      self.engine.enforceRetention()
    }
    libraryStore.onChange = { [weak self] in self?.libraryChanged() }
    configStore.onChange = { [weak self] old, new in self?.configChanged(from: old, to: new) }
    configStore.onStatus = { [weak self] status in self?.configStatusChanged(status) }
    configStore.startWatching()

    model.send = { [weak self] command in self?.handle(command) }
    model.updatesAvailable = appUpdater.isEnabled
    model.agentSetup = AgentSetup()
    NSApp.mainMenu = Self.mainMenu(target: self)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(statusItemClicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.setAccessibilityHelp("Shows Meeting Notes status and actions")
    }
    panel = StatusPanelController(model: model, statusButton: statusItem.button)
    panel.onVisibilityChanged = { [weak self] visible in
      guard visible, let self else { return }
      self.refreshModel()
      if Date().timeIntervalSince(self.agentsCheckedAt) > 600 { self.refreshAgents() }
    }
    onboarding.onVisibilityChanged = { [weak self] _ in self?.refreshModel() }
    // Runs on the main run loop directly so a slow frame never queues up work ahead of user
    // actions.
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.permissionTick() }
    }
    if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    teamsMonitor.onStateChanged = { [weak self] in self?.refreshModel() }
    teamsMonitor.onReading = { [weak self] in
      guard let self else { return }
      self.engine.adoptTeamsTitle(self.teamsMonitor.meetingTitle)
      self.evaluateAutoRecord()
      self.refreshModel()
    }
    teamsMonitor.onLocalParticipant = { name in
      UserDefaults.standard.set(name, forKey: Self.detectedTeamsNameKey)
    }
    updateTeamsMonitor()
    startControlServer()
    libraryStore.open()
    appUpdater.isBusy = { [weak self] in self?.updateIsBusy ?? true }
    appUpdater.start()
    var details: [String: Any] = [
      "build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown",
      "config": paths.configFile.path,
      "meetingsRoot": MeetingFiles.root.path, "socket": ControlChannel.defaultSocketURL.path,
    ]
    if let problem = configStore.problem { details["configError"] = problem }
    EventLog.shared.record("app.started", details: details)
    refreshModel()
    refreshAgents()
    // The only window that ever opens by itself: the setup, once in full and afterwards while
    // permissions are missing.
    if !OnboardingWindowController.wasShown || !permissions.missingForRecording().isEmpty {
      onboarding.show()
    }
    let urls = launchURLs ?? []
    launchURLs = nil
    if !urls.isEmpty { application(NSApp, open: urls) }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    AppLog.event("app.reopen")
    if !permissions.missingForRecording().isEmpty && !onboarding.isVisible {
      onboarding.show()
    } else {
      libraryWindow.show()
    }
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if engine.isBusy {
      let alert = NSAlert()
      alert.messageText = "Quit Meeting Notes?"
      var lines: [String] = []
      if engine.active != nil {
        lines.append("The recording stops and is saved first.")
      }
      let waiting = engine.queue.count + engine.saving.count
      if waiting > 0 || engine.active != nil {
        lines.append(
          "Meetings waiting for their transcript stay queued and continue when you open Meeting Notes again."
        )
      }
      alert.informativeText = lines.joined(separator: " ")
      alert.addButton(withTitle: "Keep Open")
      alert.addButton(withTitle: "Quit")
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    }
    controlServer?.stop()
    Task {
      await engine.prepareToQuit()
      teamsMonitor.stop()
      EventLog.shared.record("app.quit")
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  // MARK: Lifecycle events

  private func lifecycle(_ event: LifecycleEvent, _ record: MeetingRecord, _ details: [String: Any])
  {
    var logged = MeetingInfo(record: record, library: engine.library).dictionary
    logged.merge(details) { $1 }
    EventLog.shared.record(event.rawValue, meeting: record.id, details: logged)
    if let sound = MeetingSound.forEvent(
      event, status: record.status, failed: details["error"] != nil)
    {
      sounds.play(sound)
    }
    switch event {
    case .recordingStarted:
      autoRecord.recordingStarted(automatically: record.trigger == .automatic)
      problem = nil
    case .recordingStopped:
      autoRecord.recordingEnded()
    case .recordingDiscarded where record.status == .recording:
      autoRecord.recordingEnded()
    default: break
    }
    refreshModel()
  }

  // MARK: Commands

  private func handle(_ command: AppCommand) {
    switch command {
    case .meeting(let meetingCommand): run(meetingCommand, source: .panel)
    case .editConfig(let change):
      do { try configStore.update(change) } catch {
        report("Settings were not changed", error.localizedDescription)
      }
    case .setKeepAudio(let enabled): setKeepAudio(enabled)
    case .deleteAllMeetings: deleteAllMeetings()
    case .setRecordingLimit(let bytes, let done):
      setRecordingLimit(to: bytes, done: done)
    case .dismissProblem:
      problem = nil
      refreshModel()
    case .showLibrary(let id):
      panel.close()
      libraryWindow.show(selecting: id)
    case .setLaunchAtLogin(let enabled): setLaunchAtLogin(enabled)
    case .requestPermission(let permission): requestPermissions(only: permission)
    case .requestAllPermissions: requestPermissions(only: nil)
    case .openSettings(let tab):
      panel.close()
      settings.show(tab)
    case .showOnboarding:
      panel.close()
      onboarding.show()
    case .finishOnboarding: onboarding.finish()
    case .connectAgent(let id): connectAgent(id)
    case .removeAgent(let id): removeAgent(id)
    case .refreshLibrary: libraryStore.refresh()
    case .showPanel: panel.show()
    case .checkForUpdates: appUpdater.checkForUpdates()
    case .setAutomaticUpdates(let enabled):
      appUpdater.automaticUpdates = enabled
      refreshModel()
    case .open(let url): NSWorkspace.shared.open(url)
    case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
    case .copyText(let text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    case .quit: NSApp.terminate(nil)
    }
  }

  /// Runs a command from the UI; a refusal shows its reason in the panel.
  private func run(_ command: MeetingCommand, source: CommandSource) {
    Task {
      if case .failure(let error) = await commands.perform(command, source: source) {
        report(Self.failureTitle(command), error.message)
      }
    }
  }

  private static func failureTitle(_ command: MeetingCommand) -> String {
    switch command {
    case .start, .toggleRecording: return "Recording could not start"
    case .stop, .stopAndDiscard: return "Recording could not stop"
    case .retry: return "Retry failed"
    case .discard, .delete: return "Nothing was moved to the Trash"
    case .setTitle, .renameSpeakers: return "The meeting was not changed"
    case .updateSettings: return "Settings were not changed"
    case .open: return "The meeting could not be opened"
    }
  }

  private func report(_ title: String, _ reason: String) {
    AppLog.event("problem", "\(title): \(reason)")
    problem = AppProblem(title: title, reason: reason, date: Date())
    refreshModel()
    sounds.play(.error)
  }

  // MARK: Links

  func application(
    _ application: NSApplication, continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
  ) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL, url.scheme?.lowercased() == "https",
      MeetingLink(url: url) != nil
    else { return false }
    self.application(application, open: [url])
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    if launchURLs != nil {
      launchURLs?.append(contentsOf: urls)
      return
    }
    for url in urls {
      guard let command = URLCommand(url: url) else {
        EventLog.shared.record(
          "command.rejected",
          details: [
            "url": url.absoluteString, "source": CommandSource.url.rawValue,
            "reason": "Unknown command. \(URLCommand.usage)",
          ])
        continue
      }
      perform(command)
    }
  }

  private func perform(_ command: URLCommand) {
    switch command {
    case .start(let title):
      Task { await commands.perform(.start(title: title), source: .url) }
    case .stop: Task { await commands.perform(.stop, source: .url) }
    case .reveal(let id):
      let library = engine.library
      let meetings = libraryStore.snapshot.meetings
      let resolved = id.flatMap { try? MeetingLibrary.resolve($0, in: meetings) }
      let record =
        id == nil
        ? libraryStore.snapshot.latestComplete
        : resolved.flatMap { id in meetings.first { $0.id == id } }
      guard let record, let transcript = library.transcriptURL(of: record) else {
        EventLog.shared.record(
          "command.rejected",
          details: [
            "command": command.name, "source": CommandSource.url.rawValue,
            "reason": id.map { "No transcript exists for meeting \($0)." } ?? "No transcript yet.",
          ])
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting([transcript])
      EventLog.shared.record(
        "command.accepted", meeting: record.id,
        details: ["command": command.name, "source": CommandSource.url.rawValue])
    case .meeting(let link): open(link)
    }
  }

  /// Follows a meeting link with every change made before it was opened, once the meetings
  /// folder is readable.
  private func open(_ link: MeetingLink) {
    guard libraryStore.isReady else {
      pendingLink = link
      libraryWindow.show()
      return
    }
    pendingLink = nil
    Task {
      _ = await libraryStore.current()
      libraryWindow.show(link)
    }
  }

  // MARK: Control socket

  private func startControlServer() {
    let server = ControlServer { [weak self] request in
      await self?.commands.handle(request) ?? .failure("Meeting Notes is shutting down.")
    }
    do {
      try server.start()
      controlServer = server
      AppLog.event("control.listening", ControlChannel.defaultSocketURL.path)
    } catch {
      AppLog.event("control.failed", error.localizedDescription)
    }
  }

  // MARK: Status item and menus

  @objc private func statusItemClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      panel.close()
      showContextMenu()
    } else {
      panel.toggle()
    }
  }

  /// Attaching the menu for one click lets macOS place it below the status item like any other.
  private func showContextMenu() {
    guard let button = statusItem.button else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    func add(_ title: String, _ action: Selector, enabled: Bool = true) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.isEnabled = enabled
      menu.addItem(item)
    }
    if engine.active != nil {
      add("Stop & Transcribe", #selector(stopMenuItemClicked))
    } else {
      add("Start Recording", #selector(startMenuItemClicked), enabled: model.canStart)
    }
    add("Library", #selector(showLibraryMenuItemClicked))
    add("Settings…", #selector(showSettingsMenuItemClicked))
    menu.addItem(.separator())
    add("Quit", #selector(quitMenuItemClicked))
    statusItem.menu = menu
    button.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func startMenuItemClicked() {
    run(.start(title: nil), source: .panel)
  }
  @objc private func stopMenuItemClicked() { run(.stop, source: .panel) }
  @objc private func showLibraryMenuItemClicked() { libraryWindow.show() }
  @objc private func showSettingsMenuItemClicked() { settings.show(.general) }
  @objc private func showAboutMenuItemClicked() { settings.show(.about) }
  @objc private func quitMenuItemClicked() { NSApp.terminate(nil) }

  private static func mainMenu(target: MeetingAppDelegate) -> NSMenu {
    let main = NSMenu()
    let appMenu = NSMenu(title: "Meeting Notes")
    let about = NSMenuItem(
      title: "About Meeting Notes", action: #selector(showAboutMenuItemClicked), keyEquivalent: "")
    about.target = target
    appMenu.addItem(about)
    let settings = NSMenuItem(
      title: "Settings…", action: #selector(showSettingsMenuItemClicked), keyEquivalent: ",")
    settings.target = target
    appMenu.addItem(settings)
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Meeting Notes", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    main.addItem(appItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = edit
    main.addItem(editItem)
    let window = NSMenu(title: "Window")
    window.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let windowItem = NSMenuItem()
    windowItem.submenu = window
    main.addItem(windowItem)
    return main
  }

  /// Only a copy in an Applications folder owns the `meeting-notes` command, so development
  /// builds launched from elsewhere never redirect it.
  private func installCommandLineShim() {
    guard Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
    else { return }
    let executable = CommandLineInterface.executablePath
    Task.detached(priority: .utility) {
      do {
        if try CommandLineShim.install(executable: executable) {
          AppLog.event("cli.installed", executable)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profileDirectory =
          ProcessInfo.processInfo.environment["ZDOTDIR"].map {
            URL(fileURLWithPath: $0)
          } ?? home
        if try CommandLineShim.installShellPath(
          in: profileDirectory.appendingPathComponent(".zprofile"))
        {
          AppLog.event("cli.path.installed")
        }
      } catch {
        AppLog.event("cli.skipped", error.localizedDescription)
      }
    }
  }

  // MARK: Agents

  private func refreshAgents() {
    Task { await checkAgents() }
  }

  /// Checks every agent off the main thread. Only the very first check shows a spinner; later
  /// checks keep the current state until a result differs. Calls during a check join it.
  private func checkAgents() async {
    if let agentCheck { return await agentCheck.value }
    agentsCheckedAt = Date()
    for agent in model.agentSetup.agents where model.agentConnections[agent.id] == nil {
      model.agentConnections[agent.id] = .checking
    }
    let agents = model.agentSetup.agents
    let revision = agentActionRevision
    let check = Task {
      let results = await Task.detached(priority: .utility) {
        await withTaskGroup(of: (String, AgentConnection).self) { group in
          for agent in agents { group.addTask { (agent.id, AgentConnector.state(of: agent)) } }
          var results: [String: AgentConnection] = [:]
          for await (id, state) in group { results[id] = state }
          return results
        }
      }.value
      guard revision == agentActionRevision else { return }
      var states = model.agentConnections
      for (id, state) in results where !agentActions.contains(id) {
        states[id] = (states[id] ?? .checking).updated(by: state)
      }
      guard states != model.agentConnections else { return }
      for (id, state) in states where model.agentConnections[id] != state {
        AppLog.event("agent.state", "\(id); \(state)")
      }
      model.agentConnections = states
    }
    agentCheck = check
    await check.value
    agentCheck = nil
  }

  /// Re-checks the agents every few seconds while a window shows their rows, so connecting or
  /// removing one elsewhere shows up without a button.
  private func agentsVisibilityChanged(_ window: String, _ visible: Bool) {
    if visible {
      agentsShownIn.insert(window)
    } else {
      agentsShownIn.remove(window)
    }
    guard agentsShownIn.isEmpty else {
      if agentPolling == nil { pollAgents() }
      return
    }
    agentPolling?.cancel()
    agentPolling = nil
  }

  private func pollAgents() {
    agentPolling = Task { [weak self] in
      while !Task.isCancelled {
        let started = ContinuousClock.now
        await self?.checkAgents()
        try? await Task.sleep(until: started + .seconds(5))
      }
    }
  }

  /// Registers Meeting Notes after the user confirms the agent's access.
  private func connectAgent(_ id: String) {
    guard let agent = model.agentSetup.agents.first(where: { $0.id == id }) else { return }
    runAgentAction(
      agent, events: ("agent.connected", "agent.connectFailed"),
      title: "Connect Meeting Notes to \(agent.name)?",
      message:
        "\(agent.name) can read your meetings and start or stop recordings when you ask it to.",
      button: "Connect", destructive: false, command: agent.command
    ) { AgentConnector.connect(agent) }
  }

  /// Removes an agent's access after confirmation.
  private func removeAgent(_ id: String) {
    guard let agent = model.agentSetup.agents.first(where: { $0.id == id }) else { return }
    runAgentAction(
      agent, events: ("agent.removed", "agent.removeFailed"),
      title: "Remove Meeting Notes from \(agent.name)?",
      message:
        "\(agent.name) will no longer have access to Meeting Notes. You can reconnect it anytime.",
      button: "Remove", destructive: true, command: agent.removeCommand
    ) { AgentConnector.disconnect(agent) }
  }

  private func runAgentAction(
    _ agent: AgentSetup.Agent, events: (done: String, failed: String), title: String,
    message: String, button: String, destructive: Bool, command: String,
    perform: @escaping @Sendable () -> AgentConnection
  ) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: button).hasDestructiveAction = destructive
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let id = agent.id
    agentActions.insert(id)
    agentActionRevision += 1
    model.agentConnections[id] = .checking
    AppLog.event("agent.\(button.lowercased())", id)
    Task.detached {
      let state = perform()
      await MainActor.run {
        self.agentActions.remove(id)
        self.agentActionRevision += 1
        self.model.agentConnections[id] = state
        let event = state.isFailure ? events.failed : events.done
        AppLog.event(event, "\(id); \(state)")
        EventLog.shared.record(event, details: ["agent": id, "command": command])
      }
    }
  }

  // MARK: Settings

  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      report("Launch at login could not be changed", error.localizedDescription)
    }
    refreshModel()
  }

  private func configChanged(from old: AppConfig, to new: AppConfig) {
    var changed: [String] = []
    if old.mirrorTeamsMute != new.mirrorTeamsMute {
      changed.append("mirrorTeamsMute")
      if new.mirrorTeamsMute, engine.recordingRecord?.source == .teams {
        teamsMonitor.mirroredRecorder = engine.active?.recorder
      } else {
        teamsMonitor.mirroredRecorder = nil
        engine.active?.recorder.setMicrophoneMuted(false)
      }
    }
    if old.autoRecordTeamsMeetings != new.autoRecordTeamsMeetings {
      changed.append("autoRecordTeamsMeetings")
      AppLog.event("autoRecord.toggled", new.autoRecordTeamsMeetings ? "on" : "off")
      autoRecord = TeamsAutoRecordPolicy()
      updateTeamsMonitor()
    }
    if old.agentsMayCorrectTranscripts != new.agentsMayCorrectTranscripts {
      changed.append("agentsMayCorrectTranscripts")
    }
    if old.agentsMayNameMeetings != new.agentsMayNameMeetings {
      changed.append("agentsMayNameMeetings")
    }
    if old.agentsMaySummarizeMeetings != new.agentsMaySummarizeMeetings {
      changed.append("agentsMaySummarizeMeetings")
    }
    if old.keepAudio != new.keepAudio { changed.append("keepAudio") }
    if old.localSpeakerName != new.localSpeakerName { changed.append("localSpeakerName") }
    if old.retention != new.retention {
      changed.append("retention")
      engine.enforceRetention()
    }
    EventLog.shared.record("config.changed", details: ["changed": changed])
    refreshModel()
  }

  private func configStatusChanged(_ status: ConfigStore.Status) {
    switch status {
    case .valid(let warnings):
      EventLog.shared.record("config.loaded", details: ["warnings": warnings])
    case .invalid(let problem):
      EventLog.shared.record(
        "config.invalid", details: ["error": problem, "path": paths.configFile.path])
      sounds.play(.error)
    }
    refreshModel()
  }

  private func deleteAllMeetings() {
    guard libraryStore.isReady, !engine.isBusy else { return }
    Task {
      let alert = NSAlert()
      alert.messageText = "Delete all meetings?"
      alert.informativeText = "All transcripts and recordings will be moved to the Trash."
      let delete = alert.addButton(withTitle: "Delete All Meetings")
      delete.hasDestructiveAction = true
      delete.keyEquivalent = ""
      alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
      guard await present(alert) == .alertFirstButtonReturn else { return }
      do {
        let count = try engine.deleteAllMeetings()
        EventLog.shared.record("meetings.deletedAll", details: ["count": count])
      } catch {
        report("Not all meetings were deleted", error.localizedDescription)
      }
      libraryStore.refresh()
    }
  }

  private func setKeepAudio(_ enabled: Bool) {
    Task {
      let reader = libraryStore.reader
      var deleteExisting = false
      if !enabled {
        let alert = NSAlert()
        alert.messageText = "Delete existing recordings?"
        alert.informativeText =
          "Transcripts stay. Audio for unfinished meetings is kept until transcription succeeds."
        alert.addButton(withTitle: "Keep Recordings")
        let delete = alert.addButton(withTitle: "Delete Recordings")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response = await present(alert)
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
          return
        }
        deleteExisting = response == .alertSecondButtonReturn
      }
      do {
        try configStore.update { $0.keepAudio = enabled }
      } catch {
        report("Settings were not changed", error.localizedDescription)
        return
      }
      if deleteExisting {
        if let error = await reader.removeCompletedRecordings(protected: engine.protectedIDs) {
          report("Some recordings could not be deleted", error)
        }
        libraryStore.refresh()
      }
    }
  }

  /// Raising a limit applies at once; lowering it first shows what retention would delete with
  /// the new limit and applies only after confirmation.
  private func setRecordingLimit(to bytes: Int64, done: @escaping () -> Void) {
    let current = config.retention.audioBytes
    let change = SettingsChange(audioBytes: bytes)
    Task {
      defer { done() }
      if bytes < current {
        let plan = await libraryStore.retentionPlan(
          protected: engine.protectedIDs, audioBudget: bytes)
        if !plan.isEmpty, !(await confirmLowering(to: bytes, plan: plan)) { return }
      }
      if case .failure(let error) = await commands.perform(
        .updateSettings(change), source: .panel)
      {
        report("Settings were not changed", error.message)
      }
    }
  }

  private func confirmLowering(
    to bytes: Int64, plan: RecordingRetention.Plan
  ) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    alert.messageText = "Lower the recordings limit to \(size)?"
    alert.informativeText = plan.summary
    let lower = alert.addButton(withTitle: "Lower Limit")
    lower.hasDestructiveAction = true
    lower.keyEquivalent = ""
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
    return await present(alert) == .alertFirstButtonReturn
  }

  /// Shows an alert or panel as a sheet on the Settings window when it is open.
  private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    NSApp.activate(ignoringOtherApps: true)
    guard let window = settings.window, window.isVisible else { return alert.runModal() }
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
  }

  // MARK: Permissions

  private func requestPermissions(only permission: MeetingPermission?) {
    guard !requestingPermissions, !appUpdater.installation.installationStarted else { return }
    requestingPermissions = true
    refreshModel()
    Task {
      defer {
        requestingPermissions = false
        refreshModel()
      }
      AppLog.event("permissions.requested", permission?.rawValue ?? "all")
      do {
        if let permission {
          try await PermissionAccess.request(
            permission, systemAudioDenied: captureRetry.systemAudioDenied)
          if permission == .systemAudio { captureRetry.retryManually() }
        } else {
          try await PermissionAccess.requestMissing()
          if !libraryStore.access.isReadable { PermissionAccess.openFilesAndFoldersSettings() }
          captureRetry.retryManually()
        }
      } catch {
        AppLog.event("permissions.requestFailed", error.localizedDescription)
        if let denied = PermissionAccess.deniedPermission(for: error) {
          captureRetry.failed(with: error)
          PermissionAccess.openSettings(for: denied)
        } else {
          report("Permission setup failed", error.localizedDescription)
        }
      }
      await refreshPermissions()
    }
  }

  private func captureBlocked(_ permission: MeetingPermission, error: Error) {
    switch permission {
    case .microphone: permissions.microphone = false
    case .systemAudio:
      captureRetry.failed(with: error)
      permissions.systemAudio = false
    case .accessibility: permissions.accessibility = false
    case .documents: libraryStore.open()
    }
    AppLog.event("permissions.captureBlocked", permission.rawValue)
    refreshModel()
  }

  private func permissionTick() async {
    permissionTicks += 1
    let watching = settings.window?.isVisible == true || onboarding.isVisible
    if watching || permissionTicks % 3 == 0 { await refreshPermissions() }
  }

  private func refreshPermissions() async {
    guard !refreshingPermissions else { return }
    refreshingPermissions = true
    defer { refreshingPermissions = false }
    let current = PermissionSnapshot.read()
    let microphone = MicrophoneAuthorization.current()
    guard current != permissions || microphone != model.microphone else { return }
    let lostPermission =
      permissions.missingForRecording().isEmpty && !current.missingForRecording().isEmpty
    permissions = current
    AppLog.event(
      "permissions.changed", "missing=\(current.missing.map(\.rawValue).joined(separator: ","))")
    refreshModel()
    if lostPermission { onboarding.show() }
    if model.allPermissionsGranted && onboarding.isVisible
      && onboarding.isPermissionsOnly
    {
      onboarding.close()
    }
  }

  // MARK: Auto-record

  private func updateTeamsMonitor() {
    if config.autoRecordTeamsMeetings || engine.active != nil || engine.isStarting {
      teamsMonitor.start()
    } else {
      teamsMonitor.stop()
    }
  }

  private func evaluateAutoRecord() {
    guard config.autoRecordTeamsMeetings, let state = teamsMonitor.currentState else { return }
    switch autoRecord.observe(
      state.meetingPresence, at: Date(), isRecording: engine.active != nil || engine.isStarting,
      canStart: commands.startBlockedReason(automatically: true) == nil
        && captureRetry.allowsAutomaticStart)
    {
    case .start:
      AppLog.event("autoRecord.start")
      Task {
        if let error = await commands.startAutomatically() {
          report("Recording could not start", error.message)
        }
        if engine.active == nil { autoRecord.recordingEnded() }
      }
    case .stop:
      AppLog.event("autoRecord.stop")
      run(.stop, source: .autoRecord)
    case nil: break
    }
  }

  // MARK: Model

  private func engineChanged() {
    updateTeamsMonitor()
    refreshModel()
    libraryStore.refresh()
  }

  private func libraryChanged() {
    refreshModel()
    if model.allPermissionsGranted && onboarding.isVisible && onboarding.isPermissionsOnly {
      onboarding.close()
    }
    if libraryWindow.isVisible { libraryWindow.model.reload() }
    if let link = pendingLink, libraryStore.isReady { open(link) }
  }

  private func tick() {
    appUpdater.installation.resumeIfIdle(!updateIsBusy)

  }

  private func refreshModel() {
    guard let engine, let libraryStore else { return }
    let snapshot = libraryStore.snapshot
    let meetings = snapshot.meetings
    let mirroring = engine.active != nil && teamsMonitor.mirroredRecorder != nil
    let muted = mirroring && teamsMonitor.currentState == .muted
    let attention = snapshot.needingAttention.map {
      MeetingItem(record: $0, canRetry: snapshot.retryable.contains($0.id))
    }
    var processing: [String: MeetingRecord] = [:]
    if var stopping = engine.stopping {
      stopping.status = .saving
      processing[stopping.id] = stopping
    }
    for record in engine.saving + engine.queue { processing[record.id] = record }
    let queue = processing.values.sorted { $0.startedAt > $1.startedAt }
      .map { MeetingItem(record: $0) }
    let transcribing = engine.queue.first
    if let transcribing, let stage = transcribing.stage {
      model.progress = Self.progress(fromRecordStage: stage, fraction: transcribing.progress)
    } else {
      model.progress = TranscriptionProgress()
    }
    let visibleProblem =
      problem
      ?? configStore.problem.map {
        AppProblem(title: "Settings not applied", reason: $0, date: Date())
      }
    let statusInputs = PanelStatus.Inputs(
      permissions: permissions,
      folderAccess: libraryStore.access,
      folderName: PanelStatus.folderName(of: libraryStore.root),
      systemAudioBlocked: captureRetry.systemAudioDenied,
      starting: engine.isStarting, recording: engine.recordingRecord, mutedInTeams: muted,
      saving: engine.saving.first ?? engine.stopping, transcribing: transcribing,
      progress: model.progress,
      waiting: max(0, engine.queue.count - 1) + engine.saving.count,
      attentionCount: attention.count, problem: visibleProblem,
      startBlocked: commands.startBlockedReason,
      autoRecord: config.autoRecordTeamsMeetings
        && commands.startBlockedReason(automatically: true) == nil
        && captureRetry.allowsAutomaticStart,
      autoRecordPaused: autoRecord.waitingForMeetingEnd
        && teamsMonitor.currentState?.meetingPresence == .inMeeting)
    model.status = PanelStatus.make(statusInputs)
    model.headerStatus = PanelStatus.header(statusInputs)
    model.startBlockedReason = commands.startBlockedReason
    model.canStart = model.startBlockedReason == nil
    model.isRecording = engine.active != nil
    model.queue = queue
    model.attention = Array(attention)
    model.problem = visibleProblem
    model.mutedInTeams = muted
    model.folderAccess = libraryStore.access
    if model.meetings != meetings { model.meetings = meetings }
    if model.retryable != snapshot.retryable { model.retryable = snapshot.retryable }
    if model.audioFiles != snapshot.audio { model.audioFiles = snapshot.audio }
    model.config = config
    model.configProblem = configStore.problem
    model.detectedTeamsName = detectedTeamsName
    model.defaultLocalSpeakerName = TranscriptDocument.localSpeakerName(
      configured: nil, teamsName: detectedTeamsName)
    model.launchAtLogin = SMAppService.mainApp.status == .enabled
    model.permissions = permissions
    model.microphone = MicrophoneAuthorization.current()
    model.systemAudioBlocked = captureRetry.systemAudioDenied
    model.requestingPermissions = requestingPermissions
    model.canDeleteAllMeetings =
      libraryStore.isReady && !engine.isBusy && !libraryStore.snapshot.meetings.isEmpty
    model.meetingsRoot = libraryStore.root
    model.storage = snapshot.storage
    model.automaticUpdates = appUpdater.automaticUpdates
    model.canCheckForUpdates = appUpdater.canCheckForUpdates
    let kind = model.status.kindIdentifier
    if kind != announcedStatus {
      AppLog.event("status", kind)
      if !announcedStatus.isEmpty {
        NSAccessibility.post(
          element: NSApp as Any, notification: .announcementRequested,
          userInfo: [.announcement: "Meeting Notes: \(model.status.announcement)"])
      }
      announcedStatus = kind
    }
    updateIcon()
  }

  /// Rebuilds the step indicator from the stage text the engine stores in the record.
  private static func progress(fromRecordStage stage: String, fraction: Double?)
    -> TranscriptionProgress
  {
    TranscriptionProgress(recordStage: stage)
  }

  private func updateIcon() {
    guard let button = statusItem?.button else { return }
    let status = model.status
    let summary = "Meeting Notes: \(status.spokenSummary(now: Date()))"
    button.toolTip = summary
    button.setAccessibilityLabel(summary)
    switch status.tone {
    case .warning: button.image = permissionWarningImage
    case .error: button.image = errorImage
    case .recording: button.image = Self.symbolImage("waveform", .systemRed)
    case .muted: button.image = Self.symbolImage("mic.slash.fill", .systemRed)
    case .working: button.image = Self.symbolImage("waveform", .systemOrange)
    case .success: button.image = Self.symbolImage("waveform", .labelColor)
    case .neutral: button.image = Self.symbolImage("waveform", .labelColor)
    }
  }

  private static func symbolImage(_ name: String, _ color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold).applying(
      NSImage.SymbolConfiguration(paletteColors: [color]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Notes")?
      .withSymbolConfiguration(config)
    image?.isTemplate = false
    return image
  }
}

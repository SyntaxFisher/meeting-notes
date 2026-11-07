import AppKit
import SwiftUI

/// The setup window. The full setup (permissions, how recording works, coding agents) runs until
/// the user finishes it once; afterwards missing permissions bring back only the permissions page.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
  /// Set in the app's standard user defaults once the full setup was finished.
  static let completedKey = "onboardingFinished"

  private let state = OnboardingState()
  var onVisibilityChanged: ((Bool) -> Void)?
  /// Reports whether the agents step can be seen: the window is open, on screen and showing it.
  var onAgentsVisibilityChanged: ((Bool) -> Void)?
  private var agentsVisible = false {
    didSet {
      if agentsVisible != oldValue { onAgentsVisibilityChanged?(agentsVisible) }
    }
  }

  init(model: AppModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
    window.title = "Set Up Meeting Notes"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = true
    super.init(window: window)
    window.delegate = self
    let hosting = NSHostingController(rootView: OnboardingView(model: model, state: state))
    hosting.sizingOptions = [.preferredContentSize]
    window.contentViewController = hosting
    state.onPageChange = { [weak self] in self?.updateAgentsVisibility() }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  var isVisible: Bool { window?.isVisible == true }
  var isPermissionsOnly: Bool { state.permissionsOnly }

  /// Always starts at the first page, so the whole setup can be repeated after permissions were
  /// removed.
  func show() {
    state.page = .permissions
    state.permissionsOnly = UserDefaults.standard.bool(forKey: Self.completedKey)
    NSApp.activate(ignoringOtherApps: true)
    if window?.isVisible != true { window?.center() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    onVisibilityChanged?(true)
    updateAgentsVisibility()
  }

  func finish() {
    UserDefaults.standard.set(true, forKey: Self.completedKey)
    close()
  }

  func windowWillClose(_ notification: Notification) {
    onVisibilityChanged?(false)
    agentsVisible = false
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { updateAgentsVisibility() }

  private func updateAgentsVisibility() {
    guard let window else { return }
    agentsVisible =
      window.isVisible && window.occlusionState.contains(.visible) && state.page == .agents
  }
}

@MainActor
@Observable
final class OnboardingState {
  enum Page { case permissions, preferences, agents, done }
  var page = Page.permissions {
    didSet { onPageChange?() }
  }
  var permissionsOnly = false
  @ObservationIgnored var onPageChange: (() -> Void)?

  /// The page after `page`, or nil when the setup ends there. The agents step only appears when
  /// an agent is installed.
  nonisolated static func page(after page: Page, permissionsOnly: Bool, hasInstalledAgent: Bool)
    -> Page?
  {
    guard !permissionsOnly else { return nil }
    switch page {
    case .permissions: return .preferences
    case .preferences: return hasInstalledAgent ? .agents : .done
    case .agents: return .done
    case .done: return nil
    }
  }

  nonisolated static func page(before page: Page, hasInstalledAgent: Bool) -> Page? {
    switch page {
    case .permissions: return nil
    case .preferences: return .permissions
    case .agents: return .preferences
    case .done: return hasInstalledAgent ? .agents : .preferences
    }
  }
}

/// Every page has the same layout: a header, one box with either choices or information, and
/// the navigation with Back on the left and the primary action on the right.
private struct OnboardingView: View {
  let model: AppModel
  let state: OnboardingState

  var body: some View {
    VStack(spacing: 0) {
      switch state.page {
      case .permissions: permissions
      case .preferences: preferences
      case .agents: agents
      case .done: done
      }
    }
    .frame(width: 560)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var permissions: some View {
    let granted = model.allPermissionsGranted
    let next = OnboardingState.page(
      after: .permissions, permissionsOnly: state.permissionsOnly,
      hasInstalledAgent: model.hasInstalledAgent)
    return page(
      title: "Set up Meeting Notes",
      subtitle: "Allow these permissions. Everything stays on this Mac."
    ) {
      ForEach(Array(MeetingPermission.setupOrder.enumerated()), id: \.element) {
        index, permission in
        PermissionRow(model: model, permission: permission, number: index + 1)
        if index < MeetingPermission.setupOrder.count - 1 { Divider() }
      }
    } actions: {
      if granted {
        primary(next == nil ? "Done" : "Continue")
      } else {
        Button(next == nil ? "Not Now" : "Skip for Now") { advance() }
          .disabled(model.requestingPermissions)
      }
    }
  }

  private var preferences: some View {
    page(title: "Preferences", subtitle: "You can change these later in Settings.") {
      SettingRow(
        title: "Auto-record Teams meetings",
        explanation: "Starts and stops with your Teams meetings."
      ) {
        Toggle(
          "Auto-record Teams meetings",
          isOn: setting(model.autoRecord) {
            SettingsChange(autoRecordTeamsMeetings: $0)
          }
        )
        .labelsHidden()
      }
      Divider()
      SettingRow(
        title: "Mirror Teams mute",
        explanation: "Leaves your microphone out while you are muted."
      ) {
        Toggle(
          "Mirror Teams mute",
          isOn: setting(model.mirrorMute) {
            SettingsChange(mirrorTeamsMute: $0)
          }
        )
        .labelsHidden()
      }
    } actions: {
      primary("Continue")
    }
    .toggleStyle(.switch)
  }

  private var agents: some View {
    page(
      title: "Connect a coding agent",
      subtitle: "Optional. Lets your agent read and summarize your meetings."
    ) {
      ForEach(Array(model.agentSetup.agents.enumerated()), id: \.element.id) { index, agent in
        AgentRow(model: model, agent: agent)
        if index < model.agentSetup.agents.count - 1 { Divider() }
      }
    } actions: {
      primary(model.connectedAgents.isEmpty ? "Not Now" : "Continue")
    }
  }

  private var done: some View {
    let granted = model.allPermissionsGranted
    let agents = model.connectedAgents.map(\.name)
    return page(
      title: granted ? "You're all set" : "Almost ready",
      subtitle: granted
        ? "Meeting Notes lives in the menu bar."
        : "Recording works once all permissions are allowed."
    ) {
      fact(
        "person.2.wave.2", "Records your meetings",
        model.autoRecord
          ? "Starts by itself when you join a Teams meeting."
          : "Start a recording from the menu bar.")
      fact(
        "text.bubble", "Transcribes on this Mac",
        "When the meeting ends. Nothing leaves this Mac.")
      fact(
        "sparkles", "Ask your agent",
        agents.isEmpty
          ? "Connect a coding agent anytime in Settings."
          : "\(ListFormatter.localizedString(byJoining: agents)) can read your meetings.")
    } actions: {
      primary("Done")
    }
  }

  private func page<Content: View, Actions: View>(
    title: String, subtitle: String, @ViewBuilder content: () -> Content,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      header(title: title, subtitle: subtitle)
      VStack(alignment: .leading, spacing: 14, content: content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
      HStack {
        if let previous = OnboardingState.page(
          before: state.page, hasInstalledAgent: model.hasInstalledAgent),
          !state.permissionsOnly
        {
          Button("Back") { state.page = previous }
        }
        Spacer()
        actions()
      }
      .controlSize(.large)
    }
    .padding(28)
    .padding(.top, 8)
  }

  /// Goes to the next page, or finishes the setup on the last one.
  private func advance() {
    if let next = OnboardingState.page(
      after: state.page, permissionsOnly: state.permissionsOnly,
      hasInstalledAgent: model.hasInstalledAgent)
    {
      state.page = next
    } else {
      model.send(.finishOnboarding)
    }
  }

  private func primary(_ title: String) -> some View {
    Button(title, action: advance)
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
  }

  private func setting(_ value: Bool, _ change: @escaping (Bool) -> SettingsChange)
    -> Binding<Bool>
  {
    Binding(get: { value }, set: { model.send(.meeting(.updateSettings(change($0)))) })
  }

  private func header(title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
        Text(subtitle)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func fact(_ symbol: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

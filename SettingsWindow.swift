import AppKit
import SwiftUI

extension SettingsTab {
  var title: String {
    switch self {
    case .general: return "General"
    case .agents: return "Agents"
    case .permissions: return "Permissions"
    case .advanced: return "Advanced"
    case .about: return "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: return "gearshape"
    case .agents: return "sparkles"
    case .permissions: return "lock.shield"
    case .advanced: return "gearshape.2"
    case .about: return "info.circle"
    }
  }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let tabs = InstantResizeTabController()
  var onVisibilityChanged: ((Bool) -> Void)?
  /// Reports whether the Agents tab can be seen: the window is open, on screen and showing it.
  var onAgentsVisibilityChanged: ((Bool) -> Void)?
  private var agentsVisible = false {
    didSet {
      if agentsVisible != oldValue { onAgentsVisibilityChanged?(agentsVisible) }
    }
  }

  init(model: AppModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    tabs.tabStyle = .toolbar
    tabs.transitionOptions = []
    for tab in SettingsTab.allCases {
      let hosting = NSHostingController(rootView: SettingsTabView(tab: tab, model: model))
      hosting.sizingOptions = [.preferredContentSize]
      hosting.title = tab.title
      let item = NSTabViewItem(viewController: hosting)
      item.label = tab.title
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
      item.identifier = tab.rawValue
      tabs.addTabViewItem(item)
    }
    window.contentViewController = tabs
    window.toolbarStyle = .preference
    tabs.onSelect = { [weak self] in self?.updateAgentsVisibility() }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func show(_ tab: SettingsTab) {
    if let index = SettingsTab.allCases.firstIndex(of: tab) {
      tabs.selectedTabViewItemIndex = index
    }
    tabs.fitWindow()
    NSApp.activate(ignoringOtherApps: true)
    if window?.isVisible != true { window?.center() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    onVisibilityChanged?(true)
    updateAgentsVisibility()
  }

  func windowWillClose(_ notification: Notification) {
    onVisibilityChanged?(false)
    agentsVisible = false
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { updateAgentsVisibility() }

  private func updateAgentsVisibility() {
    guard let window else { return }
    agentsVisible =
      window.isVisible && window.occlusionState.contains(.visible)
      && SettingsTab.allCases[safe: tabs.selectedTabViewItemIndex] == .agents
  }
}

/// Fits the window to the selected tab at once. The stock controller animates every resize, and
/// SwiftUI reports a tab's size only after it appears, so a switch would visibly lag.
private final class InstantResizeTabController: NSTabViewController {
  var onSelect: (() -> Void)?

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    fitWindow()
    onSelect?()
  }

  override func preferredContentSizeDidChange(for viewController: NSViewController) {
    guard viewController === tabViewItems[safe: selectedTabViewItemIndex]?.viewController else {
      return
    }
    fitWindow()
  }

  func fitWindow() {
    guard let window = view.window,
      let content = tabViewItems[safe: selectedTabViewItemIndex]?.viewController?.view
    else { return }
    let size = content.fittingSize
    guard size.width > 0, size.height > 0 else { return }
    let old = window.frame
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
    guard frame != old else { return }
    window.setFrame(frame, display: true, animate: false)
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private struct SettingsTabView: View {
  let tab: SettingsTab
  let model: AppModel

  var body: some View {
    Group {
      switch tab {
      case .general: GeneralSettings(model: model)
      case .permissions: PermissionSettings(model: model)
      case .agents: AgentSettings(model: model)
      case .advanced: AdvancedSettings(model: model)
      case .about: AboutSettings(model: model)
      }
    }
    .frame(width: 600)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// A labeled control with an optional one-line explanation; shared by Settings and the setup
/// window.
struct SettingRow<Control: View>: View {
  let title: String
  var explanation: String? = nil
  @ViewBuilder let control: Control

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let explanation {
          Text(explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 16)
      control
    }
    .accessibilityElement(children: .contain)
  }
}

private struct GeneralSettings: View {
  let model: AppModel
  @State private var localName = ""

  var body: some View {
    Form {
      Section {
        SettingRow(title: "Launch at login") {
          Toggle(
            "Launch at login",
            isOn: Binding(
              get: { model.launchAtLogin }, set: { model.send(.setLaunchAtLogin($0)) })
          )
          .labelsHidden()
        }
        SettingRow(
          title: "Auto-record Teams meetings",
          explanation: "Starts and stops with your Teams meetings."
        ) {
          Toggle(
            "Auto-record Teams meetings",
            isOn: setting(model.autoRecord) { SettingsChange(autoRecordTeamsMeetings: $0) }
          )
          .labelsHidden()
        }
        SettingRow(
          title: "Mirror Teams mute",
          explanation: "Leaves your microphone out while you are muted."
        ) {
          Toggle(
            "Mirror Teams mute",
            isOn: setting(model.mirrorMute) { SettingsChange(mirrorTeamsMute: $0) }
          )
          .labelsHidden()
        }
        SettingRow(title: "Your name in transcripts") {
          TextField("Your name", text: $localName, prompt: Text(model.defaultLocalSpeakerName))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .onSubmit(saveLocalName)
            .accessibilityLabel("Your name in transcripts")
            .help(localNameHelp)
        }
      }
      .disabled(!model.configWritable)
      if let problem = model.configProblem {
        Section {
          Label(
            "config.json is invalid: \(problem)",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .formStyle(.grouped)
    .toggleStyle(.switch)
    .onAppear { localName = model.config.localSpeakerName ?? "" }
    .onChange(of: model.config.localSpeakerName) { _, name in localName = name ?? "" }
    .onDisappear(perform: saveLocalName)
  }

  private var localNameHelp: String {
    let source = model.detectedTeamsName != nil ? "your Teams name" : "your macOS name"
    return "Labels your microphone. Empty uses \(source)."
  }

  private func saveLocalName() {
    let name = TranscriptDocument.cleanedName(localName)
    guard name != model.config.localSpeakerName else { return }
    model.send(.meeting(.updateSettings(SettingsChange(localSpeakerName: .some(name)))))
  }

  private func setting(_ value: Bool, _ change: @escaping (Bool) -> SettingsChange)
    -> Binding<Bool>
  {
    Binding(get: { value }, set: { model.send(.meeting(.updateSettings(change($0)))) })
  }
}

struct PermissionRow: View {
  let model: AppModel
  let permission: MeetingPermission
  var number: Int?

  var body: some View {
    let granted = model.granted(permission)
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle().fill(granted ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
        Image(systemName: granted ? "checkmark" : permission.symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(granted ? Color.green : Color.orange)
          .contentTransition(.symbolEffect(.replace))
      }
      .frame(width: 32, height: 32)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(number.map { "\($0). \(permission.title)" } ?? permission.title)
            .font(.headline)
          Text(model.statusText(for: permission))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
              Capsule().fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            )
            .foregroundStyle(granted ? Color.green : Color.orange)
        }
        Text(permission.explanation)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if granted {
        Button("Open Settings…") { PermissionAccess.openSettings(for: permission) }
          .controlSize(.small)
          .help("Opens \(permission.title) in System Settings")
      } else {
        Button("Allow") {
          model.send(.requestPermission(permission))
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.requestingPermissions)
        .help("Allow \(permission.title) access")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(permission.title): \(model.statusText(for: permission))")
  }
}

private struct PermissionSettings: View {
  let model: AppModel

  var body: some View {
    Form {
      Section {
        ForEach(MeetingPermission.setupOrder, id: \.self) { permission in
          PermissionRow(model: model, permission: permission)
            .padding(.vertical, 4)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct StorageSection: View {
  let model: AppModel

  var body: some View {
    Section {
      SettingRow(title: "Meetings folder") {
        HStack(spacing: 8) {
          Text(Self.abbreviated(model.config.meetingsRootURL))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Button {
            model.send(.open(model.meetingsRoot))
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Open the meetings folder")
          .accessibilityLabel("Open meetings folder")
          Button("Delete All Meetings…", role: .destructive) { model.send(.deleteAllMeetings) }
            .disabled(!model.canDeleteAllMeetings)
            .help(
              "Delete all transcripts and recordings when no recording or transcription is running")
        }
      }
      SettingRow(
        title: "Keep audio recordings",
        explanation:
          "When off, audio is deleted after successful transcription."
      ) {
        Toggle(
          "Keep audio recordings",
          isOn: Binding(
            get: { model.config.keepAudio },
            set: { enabled in model.send(.setKeepAudio(enabled)) })
        )
        .labelsHidden()
      }
      if model.config.keepAudio {
        LimitRow(
          model: model,
          bytes: model.storage.audioBytes, budget: model.config.retention.audioBytes)
      }
    } header: {
      Text("Storage")
    } footer: {
      Text(
        "Above the audio limit, the oldest recordings are deleted. Transcripts are always kept."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .disabled(!model.configWritable)
  }

  static func abbreviated(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
  }
}

/// A folder's usage and its limit. Lowering the limit may ask for confirmation first, so the
/// picker shows the chosen value until the app has applied or cancelled it.
private struct LimitRow: View {
  let model: AppModel
  private let title = "Recordings"
  private let subfolder = "audios"
  let bytes: Int64
  let budget: Int64
  @State private var pending: Int64?

  private static let choices: [Int64] = [1, 2, 5, 10, 20, 50, 100].map { $0 * 1_000_000_000 }

  private var options: [Int64] {
    Self.choices.contains(budget) ? Self.choices : (Self.choices + [budget]).sorted()
  }

  private var selection: Binding<Int64> {
    Binding(
      get: { pending ?? budget },
      set: { bytes in
        guard bytes != budget, pending == nil else { return }
        pending = bytes
        model.send(.setRecordingLimit(bytes: bytes, done: { pending = nil }))
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(title)
        Spacer()
        Text("\(Self.size(bytes)) of")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Picker("\(title) limit", selection: selection) {
          ForEach(options, id: \.self) { Text(Self.size($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(pending != nil)
        .accessibilityLabel("\(title) limit")
        Button {
          model.send(.open(model.meetingsRoot.appendingPathComponent(subfolder)))
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Open the \(subfolder) folder")
        .accessibilityLabel("Open \(title) folder")
      }
      ProgressView(value: min(1, Double(bytes) / Double(budget)))
        .tint(bytes > budget ? .orange : .accentColor)
        .accessibilityLabel("\(title): \(Self.size(bytes)) of \(Self.size(budget))")
    }
    .accessibilityElement(children: .contain)
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// Who made it, which version runs, updates, and the open-source parts it is built on.
private struct AboutSettings: View {
  let model: AppModel

  var body: some View {
    Form {
      Section {
        HStack(spacing: 14) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text("Meeting Notes").font(.title3.weight(.semibold))
            Text(model.version)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            Button("Diagnostic Log") {
              model.send(
                .reveal(model.paths.logDirectory.appendingPathComponent("meeting-notes.log")))
            }
            .buttonStyle(.link)
            .font(.callout)
          }
          Spacer()
          Button("Check for Updates…") { model.send(.checkForUpdates) }
            .disabled(!model.canCheckForUpdates)
        }
        .padding(.vertical, 2)
        SettingRow(
          title: "Install updates automatically",
          explanation: model.updatesAvailable ? nil : "Updates are unavailable in this build."
        ) {
          Toggle(
            "Install updates automatically",
            isOn: Binding(
              get: { model.automaticUpdates }, set: { model.send(.setAutomaticUpdates($0)) })
          )
          .labelsHidden()
          .disabled(!model.updatesAvailable)
        }
      }
      Section {
        Text("Recording and transcription run entirely on this Mac.")
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text("Uses Whisper large-v3-turbo, Silero VAD and FluidAudio.")
            .foregroundStyle(.secondary)
          HStack(spacing: 16) {
            Link(
              "GitHub", destination: URL(string: "https://github.com/SyntaxFisher/meeting-notes")!)
            Button("Licenses") { model.send(.open(Self.licenses)) }
              .buttonStyle(.link)
          }
        }
        .font(.caption)
      }
    }
    .formStyle(.grouped)
    .toggleStyle(.switch)
  }

  /// The third-party license texts, which the build collects in one folder of the bundle.
  private static var licenses: URL {
    (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent(
      "Licenses", isDirectory: true)
  }
}

/// Connect an Agent: registers Meeting Notes as an MCP server with one click, then asking the
/// agent about "my last meeting" works without copying anything. The app re-checks the agents
/// while this tab is visible. Manual setup covers other agents and the case where the one-click
/// command fails.
private struct AgentSettings: View {
  let model: AppModel

  var body: some View {
    let manualCommand = AgentSetup.manualServerCommand
    Form {
      Section {
        ForEach(model.agentSetup.agents) { agent in
          AgentRow(model: model, agent: agent)
        }
      } header: {
        Text("Let your coding agent read your meetings.")
          .font(.body)
          .foregroundStyle(.primary)
          .textCase(nil)
      }
      Section {
        SettingRow(
          title: "Allow agents to name meetings",
          explanation: "Name untitled meetings when an agent works with them."
        ) {
          Toggle(
            "Allow agents to name meetings",
            isOn: Binding(
              get: { model.config.agentsMayNameMeetings },
              set: { enabled in model.send(.editConfig { $0.agentsMayNameMeetings = enabled }) })
          )
          .labelsHidden()
        }
        SettingRow(
          title: "Allow agents to summarize meetings",
          explanation: "Add a short summary when an agent works with the meeting."
        ) {
          Toggle(
            "Allow agents to summarize meetings",
            isOn: Binding(
              get: { model.config.agentsMaySummarizeMeetings },
              set: { enabled in model.send(.editConfig { $0.agentsMaySummarizeMeetings = enabled })
              }
            )
          )
          .labelsHidden()
        }
        SettingRow(
          title: "Allow agents to correct transcription errors",
          explanation: "Fix clear recognition mistakes when an agent works with the meeting."
        ) {
          Toggle(
            "Allow agents to correct transcription errors",
            isOn: Binding(
              get: { model.config.agentsMayCorrectTranscripts },
              set: { enabled in model.send(.editConfig { $0.agentsMayCorrectTranscripts = enabled })
              }
            )
          )
          .labelsHidden()
        }
      } footer: {
        Text("When turned off, agents can still make these changes when you ask.")
      }
      .disabled(!model.configWritable)
      Section {
        CommandSetupBlock(
          model: model,
          explanation: "Add Meeting Notes to your MCP client as a stdio server using this command.",
          command: manualCommand, copyLabel: "Copy MCP command")
      } header: {
        Text("Manual setup")
      }

    }
    .formStyle(.grouped)
  }
}

/// One coding agent with its connection state and the action that changes it; shared by
/// Settings and the setup window.
struct AgentRow: View {
  let model: AppModel
  let agent: AgentSetup.Agent

  var body: some View {
    let state = model.agentConnections[agent.id] ?? .checking
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Image(systemName: Self.symbol(state))
          .foregroundStyle(state == .connected ? .green : .secondary)
          .accessibilityHidden(true)
        Text(agent.name)
        Spacer()
        action(state)
      }
      .frame(minHeight: 24)
      if let message = Self.error(state) {
        Text(message)
          .font(.caption.monospaced())
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(agent.name): \(Self.label(state))")
  }

  @ViewBuilder private func action(_ state: AgentConnection) -> some View {
    switch state {
    case .checking:
      ProgressView().controlSize(.small)
    case .connected:
      Button("Remove…") { model.send(.removeAgent(agent.id)) }
        .help(agent.removeCommand)
    case .notConnected:
      Button("Connect…") { model.send(.connectAgent(agent.id)) }
        .help(agent.command)
    case .failed:
      Button("Try Again…") { model.send(.connectAgent(agent.id)) }
    case .removeFailed:
      Button("Try Again…") { model.send(.removeAgent(agent.id)) }
    case .notInstalled:
      Text(Self.label(state)).foregroundStyle(.secondary)
    }
  }

  static func symbol(_ state: AgentConnection) -> String {
    switch state {
    case .connected: return "checkmark.circle.fill"
    case .failed, .removeFailed: return "exclamationmark.triangle.fill"
    case .notInstalled: return "circle.dashed"
    case .checking, .notConnected: return "circle"
    }
  }

  static func error(_ state: AgentConnection) -> String? {
    switch state {
    case .failed(let message), .removeFailed(let message): return message
    default: return nil
    }
  }

  static func label(_ state: AgentConnection) -> String {
    switch state {
    case .checking: return "Checking…"
    case .notInstalled: return "Not installed"
    case .notConnected: return "Not connected"
    case .connected: return "Connected"
    case .failed: return "Could not connect"
    case .removeFailed: return "Could not remove"
    }
  }
}

private struct CommandRow: View {
  let command: String
  let copy: () -> Void
  @State private var copied = false

  var body: some View {
    HStack {
      Text(command)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(copied ? "Copied" : "Copy") {
        copy()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
      }
      .controlSize(.small)
      .accessibilityLabel("Copy the command line command")
    }
  }
}

/// For power users: storage, the command line, URL commands and the event log.
private struct AdvancedSettings: View {
  let model: AppModel

  var body: some View {
    Form {
      StorageSection(model: model)
      Section {
        CommandSetupBlock(
          model: model,
          explanation: "Run this command in Terminal to explore the available commands.",
          command: "meeting-notes help", copyLabel: "Copy automation command")
      } header: {
        Text("Automation")
      }
    }
    .formStyle(.grouped)
  }
}

private struct CommandSetupBlock: View {
  let model: AppModel
  let explanation: String
  let command: String
  let copyLabel: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(explanation)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Text(command)
          .font(.system(.body, design: .monospaced).weight(.medium))
          .textSelection(.enabled)
        Spacer()
        Button {
          model.send(.copyText(command))
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy command")
        .accessibilityLabel(copyLabel)
      }
      .padding(12)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
    .padding(.vertical, 4)
  }
}

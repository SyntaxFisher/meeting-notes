import AVFoundation
import AppKit
import Observation

/// What the windows ask the app delegate to do. Meeting actions go through the command layer
/// as `.meeting`, so the UI is validated exactly like agents and scripts.
enum AppCommand {
  case meeting(MeetingCommand)
  case editConfig((inout AppConfig) -> Void)
  case setKeepAudio(Bool)
  /// Asks for a folder, then makes it the meetings folder.
  case deleteAllMeetings
  /// Asks for confirmation when the new limit deletes meetings right away; `done` runs when the
  /// limit was applied or the change was cancelled.
  case setRecordingLimit(bytes: Int64, done: () -> Void)
  case dismissProblem
  case showLibrary(id: String?)
  case setLaunchAtLogin(Bool)
  case requestPermission(MeetingPermission)
  case requestAllPermissions
  case openSettings(SettingsTab)
  case showOnboarding
  case finishOnboarding
  case showPanel
  case checkForUpdates
  case setAutomaticUpdates(Bool)
  case open(URL)
  case reveal(URL)
  case copyText(String)
  case connectAgent(String)
  case removeAgent(String)
  /// Rereads the meetings folder in the background.
  case refreshLibrary
  case quit
}

enum SettingsTab: String, CaseIterable {
  case general, agents, permissions, advanced, about
}

enum MicrophoneAuthorization {
  case notDetermined, denied, authorized

  static func current() -> Self {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .authorized
    case .notDetermined: return .notDetermined
    default: return .denied
    }
  }
}

/// A meeting the panel lists, with what its buttons may do.
struct MeetingItem: Identifiable, Equatable {
  let record: MeetingRecord
  var canRetry = false
  var id: String { record.id }
}

/// The state every window renders. The app delegate owns the logic and writes into it.
@MainActor
@Observable
final class AppModel {
  var status: PanelStatus = .ready(.manual)
  var headerStatus: PanelStatus = .ready(.manual)
  var canStart = false
  var canDeleteAllMeetings = false
  var startBlockedReason: String?
  var isRecording = false
  var progress = TranscriptionProgress()
  var queue: [MeetingItem] = []
  var attention: [MeetingItem] = []
  var problem: AppProblem?
  var mutedInTeams = false
  /// Every meeting, newest first, as last read from the meetings folder.
  var meetings: [MeetingRecord] = []
  var retryable: Set<String> = []
  var audioFiles: [String: URL] = [:]
  var folderAccess = MeetingsFolderAccess.checking
  var config = AppConfig()
  var configProblem: String?
  var defaultLocalSpeakerName = ""
  var detectedTeamsName: String?
  var paths = AutomationPaths.standard
  var launchAtLogin = false
  var permissions = PermissionSnapshot(
    microphone: false, systemAudio: false, accessibility: false)
  var microphone = MicrophoneAuthorization.notDetermined
  var systemAudioBlocked = false
  var requestingPermissions = false
  var storage = RecordingRetention.Usage()
  var meetingsRoot = MeetingFiles.root
  var updatesAvailable = false
  var automaticUpdates = false
  var canCheckForUpdates = false
  var agentSetup = AgentSetup()
  var agentConnections: [String: AgentConnection] = [:]

  /// Agents that already have Meeting Notes as an MCP server.
  var connectedAgents: [AgentSetup.Agent] {
    agentSetup.agents.filter { agentConnections[$0.id] == .connected }
  }

  /// Whether any agent's tool is installed, or the first check has not finished yet.
  var hasInstalledAgent: Bool {
    agentSetup.agents.contains { agentConnections[$0.id] != .notInstalled }
  }

  /// Whether an installed agent could be connected and none is connected yet.
  var suggestsConnectingAgent: Bool {
    let states = agentSetup.agents.compactMap { agentConnections[$0.id] }
    guard !states.contains(.connected), !states.contains(.checking) else { return false }
    return states.contains {
      if case .failed = $0 { return true }
      return $0 == .notConnected
    }
  }

  var isPreview = false
  @ObservationIgnored var send: (AppCommand) -> Void = { _ in }

  var autoRecord: Bool { config.autoRecordTeamsMeetings }
  var mirrorMute: Bool { config.mirrorTeamsMute }
  var configWritable: Bool { configProblem == nil }
  var allPermissionsGranted: Bool { MeetingPermission.setupOrder.allSatisfy(granted) }

  func granted(_ permission: MeetingPermission) -> Bool {
    switch permission {
    case .microphone: return permissions.microphone
    case .systemAudio: return permissions.systemAudio && !systemAudioBlocked
    case .accessibility: return permissions.accessibility
    case .documents: return folderAccess.isReadable
    }
  }

  func statusText(for permission: MeetingPermission) -> String {
    granted(permission) ? "Allowed" : "Not allowed"
  }

  var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    return "Version \(short) (\(build))"
  }
}

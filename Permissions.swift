import AVFoundation
import AppKit
import CoreAudio

enum MeetingPermission: String {
  case microphone, accessibility, systemAudio, documents

  var title: String {
    switch self {
    case .microphone: return "Microphone"
    case .systemAudio: return "System Audio Recording"
    case .accessibility: return "Accessibility"
    case .documents: return "Documents"
    }
  }

  var explanation: String {
    switch self {
    case .microphone: return "Records your voice."
    case .systemAudio: return "Records the other participants in Teams."
    case .accessibility: return "Detects Teams meetings, titles and mute."
    case .documents: return "Saves your recordings and transcripts."
    }
  }

  var symbol: String {
    switch self {
    case .microphone: return "mic.fill"
    case .systemAudio: return "speaker.wave.2.fill"
    case .accessibility: return "accessibility"
    case .documents: return "folder"
    }
  }

  /// The System Settings pane where the user grants this permission.
  var settingsURL: URL {
    let anchor: String
    switch self {
    case .microphone: anchor = "Privacy_Microphone"
    case .systemAudio: anchor = "Privacy_ScreenCapture"
    case .accessibility: anchor = "Privacy_Accessibility"
    case .documents: anchor = "Privacy_FilesAndFolders"
    }
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
  }

  static let setupOrder: [MeetingPermission] = [
    .documents, .microphone, .systemAudio, .accessibility,
  ]
}

struct PermissionRequired: Error {
  let permission: MeetingPermission
}

struct PermissionSnapshot: Equatable {
  var microphone: Bool
  var systemAudioRequested: Bool
  var accessibility: Bool

  var missing: [MeetingPermission] {
    var result: [MeetingPermission] = []
    if !microphone { result.append(.microphone) }
    if !systemAudioRequested { result.append(.systemAudio) }
    if !accessibility { result.append(.accessibility) }
    return result
  }
  var recordingGranted: Bool { missing.isEmpty }

  func missingForRecording(automatically: Bool = false) -> [MeetingPermission] {
    missing.filter {
      switch $0 {
      case .microphone: true
      case .systemAudio: true
      case .accessibility: automatically
      case .documents: true
      }
    }
  }

  static func read() -> Self {
    Self(
      microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      systemAudioRequested: PermissionAccess.systemAudioWasRequested(),
      accessibility: TeamsMuteReader.hasAccessibilityAccess)
  }
}

struct CaptureRetryPolicy {
  private(set) var systemAudioDenied = false
  var allowsAutomaticStart: Bool { !systemAudioDenied }

  mutating func failed(with error: Error) {
    if PermissionAccess.deniedPermission(for: error) == .systemAudio {
      systemAudioDenied = true
    }
  }

  mutating func retryManually() { systemAudioDenied = false }
}

enum PermissionAccess {
  static let systemAudioGuidance =
    "Allow Meeting Notes in System Settings > Privacy & Security > Screen & System Audio Recording, then set up System Audio Recording again."

  private static let systemAudioSetupKey = "systemAudioSetupBuild"
  private static var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development"
  }

  // This records a completed setup request, not the current macOS authorization state.
  static func systemAudioWasRequested(defaults: UserDefaults = .standard) -> Bool {
    guard let setupBuild = defaults.string(forKey: systemAudioSetupKey) else { return false }
    return !setupBuild.isEmpty
  }

  static func invalidateSystemAudioRequest(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: systemAudioSetupKey)
  }

  static func deniedPermission(for error: Error) -> MeetingPermission? {
    if let required = error as? PermissionRequired { return required.permission }
    if let failure = error as? CoreAudioFailure, failure.status == kAudioDevicePermissionsError {
      return .systemAudio
    }
    return nil
  }

  @MainActor
  static func openSettings(for permission: MeetingPermission) {
    NSWorkspace.shared.open(permission.settingsURL)
  }

  static func openFilesAndFoldersSettings() {
    NSWorkspace.shared.open(
      URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
  }

  /// Requests one permission. Prompts once while macOS has not asked yet, otherwise opens the
  /// matching System Settings pane because macOS only lets the user change it there.
  @MainActor
  static func request(_ permission: MeetingPermission, systemAudioDenied: Bool) async throws {
    NSApp.activate(ignoringOtherApps: true)
    switch permission {
    case .microphone:
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .notDetermined:
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
          throw PermissionRequired(permission: .microphone)
        }
      case .authorized: break
      default: openSettings(for: .microphone)
      }
    case .systemAudio:
      if systemAudioDenied {
        openSettings(for: .systemAudio)
        return
      }
      try await requestSystemAudio()
    case .accessibility:
      guard !TeamsMuteReader.hasAccessibilityAccess else { return }
      TeamsMuteReader.requestAccess()
      openSettings(for: .accessibility)
    case .documents:
      openFilesAndFoldersSettings()
    }
  }

  @MainActor
  private static func requestSystemAudio() async throws {
    invalidateSystemAudioRequest()
    AppLog.event("permissions.systemAudioRequested")
    try await SystemAudioCapture.requestAccess()
    UserDefaults.standard.set(build, forKey: systemAudioSetupKey)
    AppLog.event("permissions.systemAudioRequestFinished")
  }

  @MainActor
  static func requestMissing() async throws {
    NSApp.activate(ignoringOtherApps: true)
    try await requestInOrder(
      microphone: {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      },
      systemAudio: { try await requestSystemAudio() },
      accessibility: {
        if !TeamsMuteReader.hasAccessibilityAccess { TeamsMuteReader.requestAccess() }
      })
  }

  @MainActor
  static func requestInOrder(
    microphone: () async -> Bool,
    systemAudio: () async throws -> Void,
    accessibility: () -> Void
  ) async throws {
    guard await microphone() else { throw PermissionRequired(permission: .microphone) }
    try await systemAudio()
    accessibility()
  }
}

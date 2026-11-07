import AVFoundation
import AppKit
import CoreAudio
import Darwin

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
  var systemAudio: Bool
  var accessibility: Bool

  var missing: [MeetingPermission] {
    var result: [MeetingPermission] = []
    if !microphone { result.append(.microphone) }
    if !systemAudio { result.append(.systemAudio) }
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
      systemAudio: SystemAudioAuthorization.current() == .authorized,
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
      switch SystemAudioAuthorization.current() {
      case .authorized: break
      case .notDetermined where !systemAudioDenied: try await requestSystemAudio()
      default: openSettings(for: .systemAudio)
      }
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
    AppLog.event("permissions.systemAudioRequested")
    let granted = await SystemAudioAuthorization.request()
    AppLog.event("permissions.systemAudioRequestFinished", granted ? "granted" : "denied")
    guard granted else { throw PermissionRequired(permission: .systemAudio) }
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
      systemAudio: {
        if SystemAudioAuthorization.current() != .authorized { try await requestSystemAudio() }
      },
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

/// macOS's System Audio Recording decision for this app. macOS has no public API for it, so it
/// is read from TCC. Where TCC's functions are unavailable, access counts as authorized and a
/// denial surfaces as a capture failure instead.
enum SystemAudioAuthorization: Equatable {
  case authorized, denied, notDetermined

  private static let service = "kTCCServiceAudioCapture" as CFString

  /// Whether this macOS provides TCC's functions, so the status is macOS's actual decision.
  static var isReadable: Bool { TCC.preflight != nil && TCC.request != nil }

  static func current() -> Self {
    guard let preflight = TCC.preflight else { return .authorized }
    switch preflight(service, nil) {
    case 0: return .authorized
    case 1: return .denied
    default: return .notDetermined
    }
  }

  /// Asks macOS, which prompts while the user has not decided yet. Unlike starting a capture,
  /// this prompts even when no app is playing audio.
  static func request() async -> Bool {
    guard let request = TCC.request else { return true }
    return await withCheckedContinuation { continuation in
      request(service, nil) { continuation.resume(returning: $0) }
    }
  }

  private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    typealias Request =
      @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let handle = dlopen(
      "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    static let preflight = symbol("TCCAccessPreflight", as: Preflight.self)
    static let request = symbol("TCCAccessRequest", as: Request.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
      guard let handle, let pointer = dlsym(handle, name) else { return nil }
      return unsafeBitCast(pointer, to: type)
    }
  }
}

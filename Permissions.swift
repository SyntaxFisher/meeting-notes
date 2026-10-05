import AVFoundation
import AppKit
import CoreAudio

enum MeetingPermission: String {
  case microphone, accessibility, systemAudio

  var title: String {
    switch self {
    case .microphone: return "Microphone"
    case .systemAudio: return "System Audio Recording"
    case .accessibility: return "Accessibility"
    }
  }
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

  static func read() -> Self {
    Self(
      microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      systemAudioRequested: PermissionAccess.systemAudioWasRequested,
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
    "Allow Meeting Notes in System Settings > Privacy & Security > Screen & System Audio Recording, then choose Grant Permissions to retry setup."

  private static let systemAudioSetupKey = "systemAudioSetupBuild"
  private static var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development"
  }

  // This records a completed setup request, not the current macOS authorization state.
  static var systemAudioWasRequested: Bool {
    UserDefaults.standard.string(forKey: systemAudioSetupKey) == build
  }

  static func invalidateSystemAudioRequest() {
    UserDefaults.standard.removeObject(forKey: systemAudioSetupKey)
  }

  static func deniedPermission(for error: Error) -> MeetingPermission? {
    if let required = error as? PermissionRequired { return required.permission }
    if let failure = error as? CoreAudioFailure, failure.status == kAudioDevicePermissionsError {
      return .systemAudio
    }
    return nil
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
        invalidateSystemAudioRequest()
        AppLog.event("permissions.systemAudioRequested")
        try await TeamsAudioCapture.requestAccess()
        UserDefaults.standard.set(build, forKey: systemAudioSetupKey)
        AppLog.event("permissions.systemAudioRequestFinished")
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

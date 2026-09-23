import AVFoundation
import AppKit
import ScreenCaptureKit

enum MeetingPermission: String, CaseIterable {
  case microphone, accessibility, screenRecording

  var title: String {
    switch self {
    case .microphone: return "Microphone"
    case .screenRecording: return "Screen & System Audio Recording"
    case .accessibility: return "Accessibility"
    }
  }

}

struct PermissionRequired: Error {
  let permission: MeetingPermission
}

struct PermissionSnapshot: Equatable {
  var microphone: Bool
  var screenRecording: Bool
  var accessibility: Bool

  var missing: [MeetingPermission] {
    MeetingPermission.allCases.filter {
      switch $0 {
      case .microphone: return !microphone
      case .screenRecording: return !screenRecording
      case .accessibility: return !accessibility
      }
    }
  }
  var recordingGranted: Bool { missing.isEmpty }

  static func read() -> Self {
    Self(
      microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      screenRecording: CGPreflightScreenCaptureAccess(),
      accessibility: TeamsMuteReader.hasAccessibilityAccess)
  }
}

struct ScreenPermissionContinuation {
  var waitingForAccessibility = false

  mutating func consumeRequest(for permissions: PermissionSnapshot) -> Bool {
    guard waitingForAccessibility else { return false }
    if permissions.screenRecording {
      waitingForAccessibility = false
      return false
    }
    guard permissions.microphone && permissions.accessibility else { return false }
    // Consume before requesting so denial cannot trigger another automatic prompt.
    waitingForAccessibility = false
    return true
  }
}

enum PermissionAccess {
  enum RequestResult { case finished, waitingForAccessibility }
  static func deniedPermission(for error: Error) -> MeetingPermission? {
    if let required = error as? PermissionRequired { return required.permission }
    let error = error as NSError
    if error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    {
      return .screenRecording
    }
    if error.domain == SCStreamErrorDomain
      && error.code == SCStreamError.Code.failedToStartMicrophoneCapture.rawValue
      && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
    {
      return .microphone
    }
    return nil
  }

  @MainActor
  static func requestMissing() async -> RequestResult {
    NSApp.activate(ignoringOtherApps: true)
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return .finished }
    guard TeamsMuteReader.hasAccessibilityAccess else {
      TeamsMuteReader.requestAccess()
      return .waitingForAccessibility
    }
    if !CGPreflightScreenCaptureAccess() {
      AppLog.event("permissions.screenRequested")
      do {
        // Enumerating content requests ScreenCaptureKit access without starting a capture stream.
        _ = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        AppLog.event("permissions.screenRequestGranted")
      } catch {
        let error = error as NSError
        AppLog.event(
          "permissions.screenRequestPending", "domain=\(error.domain); code=\(error.code)")
      }
    }
    return .finished
  }

}

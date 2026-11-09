import AppKit
import ApplicationServices

enum TeamsMuteState: Hashable {
  case muted
  case unmuted
  case unavailable(Reason)

  enum Reason: Hashable {
    case accessibilityPermission
    case teamsClosed
    case noMeeting
    case noControl
    case ambiguous
    case accessibilityError

    var message: String {
      switch self {
      case .accessibilityPermission: return "Allow Meeting Notes in Accessibility settings."
      case .teamsClosed: return "Teams is closed."
      case .noMeeting: return "No active Teams meeting was found."
      case .noControl: return "The Teams microphone button was not found."
      case .ambiguous: return "The Teams microphone state is ambiguous."
      case .accessibilityError: return "Teams Accessibility could not be read."
      }
    }
  }

  var microphoneMuted: Bool { self == .muted }
}

struct TeamsWindowSnapshot {
  var title: String? = nil
  let buttons: [[String]]
  /// Whether Teams keeps this window's controls current: the compact meeting view, or the
  /// main window of Teams while it is in front. A meeting window behind other apps or
  /// minimized keeps showing the mute state it last drew.
  var isCurrent = false
}

struct TeamsReading: Equatable {
  let state: TeamsMuteState
  var meetingTitle: String? = nil
}

enum TeamsMuteClassifier {
  private static let genericTitles: Set<String> = [
    "", "microsoft teams", "meeting", "calendar", "chat", "activity", "teams", "calls",
  ]

  /// Teams can show the same meeting in more than one window: while another app is in front it
  /// opens a compact view that follows the call, and the meeting window keeps the mute button
  /// it last drew. Windows Teams keeps current decide; otherwise several meeting windows count
  /// as one state when they agree.
  static func classify(_ windows: [TeamsWindowSnapshot]) -> TeamsMuteState {
    let allMeetingWindows = windows.filter(isMeetingWindow)
    guard !allMeetingWindows.isEmpty else { return .unavailable(.noMeeting) }
    let current = allMeetingWindows.filter {
      $0.isCurrent && !$0.buttons.compactMap(classifyButton).isEmpty
    }
    let meetingWindows = current.isEmpty ? allMeetingWindows : current
    var states: Set<TeamsMuteState> = []
    for window in meetingWindows {
      let windowStates = window.buttons.compactMap(classifyButton)
      if windowStates.count > 1 { return .unavailable(.ambiguous) }
      states.formUnion(windowStates)
    }
    guard states.count == 1, let state = states.first else {
      return .unavailable(states.isEmpty ? .noControl : .ambiguous)
    }
    return state
  }

  static func meetingTitle(_ windows: [TeamsWindowSnapshot]) -> String? {
    let titles = Set(
      windows.filter { isMeetingWindow($0) && !isCompactView($0.title) }.map(\.title))
    guard titles.count == 1, var title = titles.first ?? nil else { return nil }
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [" | Microsoft Teams", " - Microsoft Teams"] where title.hasSuffix(suffix) {
      title.removeLast(suffix.count)
    }
    let components = title.components(separatedBy: " | ")
    if components.count >= 3,
      let account = components.last?.trimmingCharacters(in: .whitespacesAndNewlines),
      account.range(of: #"^[^\s@|]+@[^\s@|]+\.[^\s@|]+$"#, options: .regularExpression) != nil,
      !components[components.count - 2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      title = components.dropLast(2).joined(separator: " | ")
    }
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return genericTitles.contains(title.lowercased()) ? nil : title
  }

  /// Teams titles its compact meeting view "Meeting compact view | <meeting>".
  static func isCompactView(_ title: String?) -> Bool {
    guard let title else { return false }
    return ["Meeting compact view | ", "Kompakte Besprechungsansicht | "].contains {
      title.hasPrefix($0)
    }
  }

  private static func isMeetingWindow(_ window: TeamsWindowSnapshot) -> Bool {
    window.buttons.contains { labels in labels.contains(where: isLeaveButton) }
  }

  private static func isLeaveButton(_ label: String) -> Bool {
    label.range(
      of: #"^(?:Leave|Verlassen)(?:\b|$)"#, options: [.regularExpression, .caseInsensitive])
      != nil
  }

  private static func classifyButton(_ labels: [String]) -> TeamsMuteState? {
    let states = Set(labels.compactMap(microphoneLabel))
    if states.isEmpty { return nil }
    if states.count != 1 { return .unavailable(.ambiguous) }
    return states.first
  }

  private static func microphoneLabel(_ label: String) -> TeamsMuteState? {
    if label.range(
      of: #"^(?:Unmute mic|Mikrofon wieder aktivieren)(?:\b|$)"#,
      options: [.regularExpression, .caseInsensitive])
      != nil
    {
      return .muted
    }
    if label.range(
      of: #"^(?:Mute mic|Mikrofon stummschalten)(?:\b|$)"#,
      options: [.regularExpression, .caseInsensitive])
      != nil
    {
      return .unmuted
    }
    return nil
  }
}

enum TeamsMuteReader {
  static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

  static func requestAccess() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func read() -> TeamsReading {
    guard hasAccessibilityAccess else {
      return TeamsReading(state: .unavailable(.accessibilityPermission))
    }
    let apps = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.microsoft.teams2")
    guard apps.count == 1, let app = apps.first else {
      return TeamsReading(state: .unavailable(apps.isEmpty ? .teamsClosed : .ambiguous))
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.5)
    // Teams' web view exposes its controls in the background when enhanced accessibility is on.
    _ = AXUIElementSetAttributeValue(
      application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    guard let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) else {
      return TeamsReading(state: .unavailable(.accessibilityError))
    }
    let frontmost: Bool = attribute(application, kAXFrontmostAttribute) ?? false
    var snapshots: [TeamsWindowSnapshot] = []
    for window in windows {
      guard var snapshot = scan(window) else {
        return TeamsReading(state: .unavailable(.accessibilityError))
      }
      let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
      let main: Bool = attribute(window, kAXMainAttribute) ?? false
      snapshot.isCurrent =
        !minimized && (TeamsMuteClassifier.isCompactView(snapshot.title) || (frontmost && main))
      snapshots.append(snapshot)
    }
    return TeamsReading(
      state: TeamsMuteClassifier.classify(snapshots),
      meetingTitle: TeamsMuteClassifier.meetingTitle(snapshots))
  }

  private static func scan(_ window: AXUIElement) -> TeamsWindowSnapshot? {
    var pending: [AXUIElement] = [window]
    var buttons: [[String]] = []
    var visited = 0
    while let element = pending.popLast() {
      visited += 1
      guard visited <= 4_000 else { return nil }
      if let role: String = attribute(element, kAXRoleAttribute), role == kAXButtonRole as String {
        let labels: [String] = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
          .compactMap { attribute(element, $0) }
        buttons.append(labels)
      }
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children)
      }
    }
    return TeamsWindowSnapshot(title: attribute(window, kAXTitleAttribute), buttons: buttons)
  }

  private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }
}

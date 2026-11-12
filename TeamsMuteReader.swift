import AppKit
import ApplicationServices

enum TeamsMuteState: Hashable {
  case muted
  case unmuted
  case unavailable(Reason)

  enum Reason: String, Codable, Hashable {
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

  /// "muted", "unmuted" or "unavailable(<reason>)", as traces record it.
  var name: String {
    switch self {
    case .muted: return "muted"
    case .unmuted: return "unmuted"
    case .unavailable(let reason): return "unavailable(\(reason.rawValue))"
    }
  }

  var microphoneMuted: Bool? {
    switch self {
    case .muted: return true
    case .unmuted: return false
    case .unavailable: return nil
    }
  }
}

struct TeamsWindowSnapshot {
  var title: String? = nil
  let buttons: [[String]]
  var sharingPicker = false
  var meetingEnded = false
  var clock: TeamsCallClock? = nil
  /// Whether Teams keeps this window's controls current: the compact meeting view, or the
  /// main window of Teams while it is in front. A meeting window behind other apps or
  /// minimized keeps showing the mute state it last drew.
  var isCurrent = false
}

/// One Teams window as the mute reader read it, the input the classifier decides from. `id` is
/// stable for the window while Teams keeps it open.
struct TeamsWindowInput: Codable, Equatable {
  var id: Int
  var title: String?
  var minimized = false
  var main = false
  var buttons: [[String]] = []
  var headings: [[String]] = []
  var clock: TeamsCallClock?
}

/// The elapsed-time clock of a Teams call window: "--:--" while the call has not connected,
/// such as an outgoing call that is still ringing, then the running call time.
enum TeamsCallClock: String, Codable {
  case pending
  case running

  init?(role: String, labels: [String]) {
    guard role == kAXStaticTextRole as String else { return nil }
    let texts = labels.map { $0.trimmingCharacters(in: .whitespaces) }
    if texts.contains("--:--") {
      self = .pending
    } else if texts.contains(where: {
      $0.range(of: #"^\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
    }) {
      self = .running
    } else {
      return nil
    }
  }
}

extension TeamsWindowInput {
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(Int.self, forKey: .id),
      title: try values.decodeIfPresent(String.self, forKey: .title),
      minimized: try values.decode(Bool.self, forKey: .minimized),
      main: try values.decode(Bool.self, forKey: .main),
      buttons: try values.decode([[String]].self, forKey: .buttons),
      headings: try values.decode([[String]].self, forKey: .headings),
      clock: try values.decodeIfPresent(TeamsCallClock.self, forKey: .clock))
  }
}

/// One mute reading's input: Teams' windows and whether Teams was in front, or why Teams could
/// not be read.
struct TeamsMuteInput: Codable, Equatable {
  var frontmost = false
  var windows: [TeamsWindowInput] = []
  var failure: TeamsMuteState.Reason?

  /// The input with only the labels the classifier recognizes, so chat messages, file names
  /// and notifications shown in buttons and headings stay out of the trace. Reading the traced
  /// input gives the same state.
  var traced: TeamsMuteInput {
    var input = self
    input.windows = windows.map { window in
      var window = window
      window.buttons = window.buttons.map { $0.filter(TeamsMuteClassifier.isRecognized) }
        .filter { !$0.isEmpty }
      window.headings = window.headings.map {
        $0.filter { TeamsMuteClassifier.isSharingPicker(role: "AXHeading", labels: [$0]) }
      }.filter { !$0.isEmpty }
      return window
    }
    return input
  }
}

struct TeamsReading: Equatable {
  let state: TeamsMuteState
  var meetingTitle: String? = nil
  var connecting = false

  var meetingPresence: TeamsMeetingPresence {
    let presence = state.meetingPresence
    return presence == .inMeeting && connecting ? .connecting : presence
  }
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

  /// What one window shows the classifier.
  static func snapshot(_ window: TeamsWindowInput, frontmost: Bool) -> TeamsWindowSnapshot {
    TeamsWindowSnapshot(
      title: window.title, buttons: window.buttons,
      sharingPicker: window.headings.contains { isSharingPicker(role: "AXHeading", labels: $0) },
      meetingEnded: window.buttons.contains(where: isMeetingEndControl),
      clock: window.clock,
      isCurrent: !window.minimized && (isCompactView(window.title) || (frontmost && window.main)))
  }

  /// The reading of `input`, with `tracker` remembering meeting windows across readings.
  static func reading(_ input: TeamsMuteInput, tracker: inout TeamsMeetingWindowTracker<Int>)
    -> TeamsReading
  {
    if let failure = input.failure { return TeamsReading(state: .unavailable(failure)) }
    return tracker.observe(
      input.windows.map { ($0.id, snapshot($0, frontmost: input.frontmost)) })
  }

  /// Whether the meeting windows show the call connected, still connecting, or neither. A
  /// connected call shows its running clock or the People button in every view, so either
  /// wins over a pending clock: Teams stops updating a minimized meeting window, which then
  /// keeps showing "--:--" next to a current compact view. The compact view has no clock.
  static func callConnected(_ windows: [TeamsWindowSnapshot]) -> Bool? {
    let meetingWindows = windows.filter(isMeetingWindow)
    if meetingWindows.contains(where: {
      $0.clock == .running || $0.buttons.contains(where: isPeopleControl)
    }) {
      return true
    }
    return meetingWindows.contains { $0.clock == .pending } ? false : nil
  }

  static func isPeopleControl(_ labels: [String]) -> Bool {
    labels.contains { label in
      label.range(
        of: #"^(?:People|Personen)(?:\b|$)"#, options: [.regularExpression, .caseInsensitive])
        != nil
    }
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

  static func isMeetingWindow(_ window: TeamsWindowSnapshot) -> Bool {
    !window.meetingEnded
      && (window.sharingPicker || window.buttons.contains(where: isMeetingControl))
  }

  static func isMeetingControl(_ labels: [String]) -> Bool {
    labels.contains { label in
      label.range(
        of: #"^(?:Leave|Verlassen|Stop sharing|Freigabe beenden)(?:\b|$)"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  static func isMeetingEndControl(_ labels: [String]) -> Bool {
    labels.contains { label in
      label.range(
        of:
          #"^(?:Rejoin(?: the call)?|Erneut beitreten|Anruf erneut beitreten|Erneut teilnehmen)(?:\b|$)"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  /// Teams exposes only this popover through Accessibility while choosing what to share.
  static func isSharingPicker(role: String, labels: [String]) -> Bool {
    role == "AXHeading"
      && labels.contains {
        ["share content", "inhalt freigeben", "inhalte freigeben", "inhalt teilen"].contains(
          $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      }
  }

  /// Whether a button label is one the classifier decides from.
  static func isRecognized(_ label: String) -> Bool {
    microphoneLabel(label) != nil || isMeetingControl([label]) || isMeetingEndControl([label])
      || isPeopleControl([label])
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

/// A Teams popover can hide every call control while its meeting window remains open.
/// A closed window or explicit post-call controls establish absence; missing controls do not.
/// A call that showed it is connecting stays so until a window shows it connected or the
/// meeting ends, since a compact view that replaces its window shows neither.
struct TeamsMeetingWindowTracker<Window: Equatable> {
  private var knownWindows: [Window] = []
  private var connecting = false

  mutating func observe(_ windows: [(id: Window, snapshot: TeamsWindowSnapshot)]) -> TeamsReading {
    knownWindows.removeAll { known in
      !windows.contains { $0.id == known && !$0.snapshot.meetingEnded }
    }
    for window in windows where TeamsMuteClassifier.isMeetingWindow(window.snapshot) {
      if !knownWindows.contains(window.id) { knownWindows.append(window.id) }
    }
    let snapshots = windows.map(\.snapshot)
    var state = TeamsMuteClassifier.classify(snapshots)
    if state == .unavailable(.noMeeting), !knownWindows.isEmpty {
      state = .unavailable(.noControl)
    }
    if knownWindows.isEmpty {
      connecting = false
    } else if let connected = TeamsMuteClassifier.callConnected(snapshots) {
      connecting = !connected
    }
    return TeamsReading(
      state: state, meetingTitle: TeamsMuteClassifier.meetingTitle(snapshots),
      connecting: connecting)
  }
}

/// Numbers Teams windows by identity, so trace records and the window tracker can refer to a
/// window across readings without keeping Accessibility elements in them. Every reading looks
/// up each open window, which keeps it among the `capacity` most recently used, so an open
/// window keeps its number.
final class TeamsWindowRegistry: @unchecked Sendable {
  static let shared = TeamsWindowRegistry()
  static let capacity = 1024
  private let lock = NSLock()
  private var known: [(element: AXUIElement, id: Int)] = []
  private var next = 1

  func id(of element: AXUIElement) -> Int {
    lock.withLock {
      if let index = known.firstIndex(where: { CFEqual($0.element, element) }) {
        let entry = known.remove(at: index)
        known.append(entry)
        return entry.id
      }
      known.append((element, next))
      if known.count > Self.capacity { known.removeFirst(known.count - Self.capacity) }
      next += 1
      return next - 1
    }
  }
}

final class TeamsMuteReader {
  private var tracker = TeamsMeetingWindowTracker<Int>()

  static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

  static func requestAccess() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  func read() -> TeamsReading {
    let input = self.input()
    TeamsTrace.shared.record("mute-input", value: input.traced)
    let reading = TeamsMuteClassifier.reading(input, tracker: &tracker)
    TeamsTrace.shared.record(
      "mute",
      [
        "state": reading.state.name, "title": reading.meetingTitle ?? "",
        "connecting": reading.connecting,
      ])
    TeamsTrace.shared.record("read", always: true, [:])
    return reading
  }

  private func input() -> TeamsMuteInput {
    guard Self.hasAccessibilityAccess else {
      return TeamsMuteInput(failure: .accessibilityPermission)
    }
    let apps = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.microsoft.teams2")
    guard apps.count == 1, let app = apps.first else {
      return TeamsMuteInput(failure: apps.isEmpty ? .teamsClosed : .ambiguous)
    }
    TeamsTrace.shared.record("teams", ["version": TeamsTrace.version(of: app) ?? ""])
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.5)
    // Teams' web view exposes its controls in the background when enhanced accessibility is on.
    _ = AXUIElementSetAttributeValue(
      application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    guard let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) else {
      return TeamsMuteInput(failure: .accessibilityError)
    }
    var input = TeamsMuteInput(frontmost: attribute(application, kAXFrontmostAttribute) ?? false)
    for window in windows {
      guard var scanned = scan(window) else { return TeamsMuteInput(failure: .accessibilityError) }
      scanned.id = TeamsWindowRegistry.shared.id(of: window)
      scanned.minimized = attribute(window, kAXMinimizedAttribute) ?? false
      scanned.main = attribute(window, kAXMainAttribute) ?? false
      input.windows.append(scanned)
    }
    return input
  }

  private func scan(_ window: AXUIElement) -> TeamsWindowInput? {
    var pending: [AXUIElement] = [window]
    var input = TeamsWindowInput(id: 0, title: attribute(window, kAXTitleAttribute))
    var visited = 0
    while let element = pending.popLast() {
      visited += 1
      guard visited <= 4_000 else { return nil }
      if let role: String = attribute(element, kAXRoleAttribute),
        role == kAXButtonRole as String || role == "AXHeading"
          || (role == kAXStaticTextRole as String && input.clock == nil)
      {
        let labels: [String] = [
          kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute,
        ]
        .compactMap { attribute(element, $0) }
        if role == kAXButtonRole as String {
          input.buttons.append(labels)
        } else if role == "AXHeading" {
          input.headings.append(labels)
        } else {
          input.clock = TeamsCallClock(role: role, labels: labels)
        }
      }
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children)
      }
    }
    return input
  }

  private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }
}

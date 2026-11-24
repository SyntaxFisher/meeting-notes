import AppKit
import ApplicationServices

/// How a reading found a Teams window: Accessibility listed it, an earlier reading did (a
/// window on another desktop is not listed), or a scan of Teams' Accessibility elements did.
enum TeamsWindowOrigin: String, Codable {
  case listed, remembered, scanned
}

/// One Teams window for one reading. `refresh` is the result of asking Teams to bring the
/// window's Accessibility tree up to date, nil when the window shows no web content.
struct TeamsWindow {
  let element: AXUIElement
  let id: Int
  let origin: TeamsWindowOrigin
  let refresh: Int32?
}

/// Teams and its windows, as the mute and participant readers read them.
struct TeamsWindowList {
  let app: NSRunningApplication
  let application: AXUIElement
  let windows: [TeamsWindow]
}

extension TeamsMuteState.Reason: Error {}

/// Finds Teams' windows for the readers and keeps their Accessibility trees current.
///
/// Teams keeps updating its web content while a window is minimized, on another desktop or
/// covered, but Accessibility then reports the tree as it was when macOS last showed the
/// window. Any Accessibility action on the window's web area makes Teams publish its current
/// tree; scrolling the web area into view, which it already is, changes nothing on screen.
/// Accessibility lists only windows on the current desktop, so windows seen before stay in the
/// list until Teams closes or hides them, and while Teams shows a compact meeting view without
/// its meeting window, a throttled scan finds a meeting window no reading has seen.
///
/// Use from one queue only.
final class TeamsWindowSource {
  static let bundleIdentifier = "com.microsoft.teams2"
  static let refreshAction = "AXScrollToVisible"
  /// Seconds between scans for a missing meeting window.
  static let scanInterval = 30.0
  /// Teams numbers its Accessibility elements upward from when it started.
  static let scanLimit: UInt64 = 20_000

  private var pid: pid_t = 0
  private var known: [(element: AXUIElement, origin: TeamsWindowOrigin)] = []
  private var webAreas: [(window: AXUIElement, webArea: AXUIElement)] = []
  private var reportedFailures: Set<Int> = []
  private var lastScan: Double = -.infinity
  /// Set when the last reading found a compact meeting view but no meeting window.
  var meetingWindowMissing = false

  func read() -> Result<TeamsWindowList, TeamsMuteState.Reason> {
    guard AXIsProcessTrusted() else { return .failure(.accessibilityPermission) }
    let apps = NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.bundleIdentifier)
    guard apps.count == 1, let app = apps.first else {
      return .failure(apps.isEmpty ? .teamsClosed : .ambiguous)
    }
    if app.processIdentifier != pid {
      pid = app.processIdentifier
      known = []
      webAreas = []
      reportedFailures = []
      lastScan = -.infinity
    }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.5)
    // Teams' web view exposes its controls in the background when enhanced accessibility is on.
    _ = AXUIElementSetAttributeValue(
      application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        == .success, let listed = value as? [AXUIElement]
    else { return .failure(.accessibilityError) }

    let now = ProcessInfo.processInfo.systemUptime
    if meetingWindowMissing, now - lastScan >= Self.scanInterval {
      lastScan = now
      for window in Self.scan(pid: pid)
      where !known.contains(where: { CFEqual($0.element, window) }) {
        known.append((window, .scanned))
      }
    }
    let unlisted = known.filter { entry in
      !listed.contains { CFEqual($0, entry.element) } && Self.isOnAnotherDesktop(entry.element)
    }.map { (element: $0.element, origin: $0.origin == .scanned ? $0.origin : .remembered) }
    known = listed.map { ($0, TeamsWindowOrigin.listed) } + unlisted
    webAreas.removeAll { area in !known.contains { CFEqual($0.element, area.window) } }

    let windows = known.map { entry in
      let id = TeamsWindowRegistry.shared.id(of: entry.element)
      let refresh = refresh(entry.element)
      if let refresh, refresh != AXError.success.rawValue, Self.isOpen(entry.element),
        reportedFailures.insert(id).inserted
      {
        AppLog.event("teams.refreshFailed", "window=\(id); error=\(refresh)")
      }
      return TeamsWindow(element: entry.element, id: id, origin: entry.origin, refresh: refresh)
    }
    return .success(TeamsWindowList(app: app, application: application, windows: windows))
  }

  /// A window Teams closed no longer answers; one on another desktop does.
  private static func isOpen(_ window: AXUIElement) -> Bool {
    var role: CFTypeRef?
    return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
      != .invalidUIElement
  }

  /// Whether an unlisted window is one Teams shows on another desktop. Teams also keeps windows
  /// it does not show, such as the call window it prepares for the next call, and their
  /// Accessibility trees can repeat the controls of the call in progress. A window that is
  /// shown on some desktop is a standard window; a hidden one is not. A window Teams does not
  /// answer for in time stays in the list.
  private static func isOnAnotherDesktop(_ window: AXUIElement) -> Bool {
    var subrole: CFTypeRef?
    switch AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) {
    case .success: return subrole as? String == kAXStandardWindowSubrole as String
    case .invalidUIElement: return false
    default: return true
    }
  }

  private func refresh(_ window: AXUIElement) -> Int32? {
    let cached = webAreas.first { CFEqual($0.window, window) }?.webArea
    guard let webArea = cached ?? findWebArea(window) else { return nil }
    let result = AXUIElementPerformAction(webArea, Self.refreshAction as CFString)
    guard result == .invalidUIElement, cached != nil else { return result.rawValue }
    webAreas.removeAll { CFEqual($0.window, window) }
    guard let replacement = findWebArea(window) else { return result.rawValue }
    return AXUIElementPerformAction(replacement, Self.refreshAction as CFString).rawValue
  }

  /// The window's outermost web area: acting on an element inside it can scroll its content.
  private func findWebArea(_ window: AXUIElement) -> AXUIElement? {
    var queue = [window]
    var visited = 0
    while !queue.isEmpty, visited < 400 {
      let element = queue.removeFirst()
      visited += 1
      var role: CFTypeRef?
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
      if role as? String == "AXWebArea" {
        webAreas.append((window, element))
        return element
      }
      var children: CFTypeRef?
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
      queue.append(contentsOf: children as? [AXUIElement] ?? [])
    }
    return nil
  }

  private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

  /// The private call window switchers use to reach windows on other desktops, looked up at
  /// run time so a macOS without it only loses the scan.
  private static let createWithRemoteToken: CreateWithRemoteToken? = {
    guard
      let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken")
    else { return nil }
    return unsafeBitCast(symbol, to: CreateWithRemoteToken.self)
  }()

  /// Teams' windows by element number, also those Accessibility does not list.
  private static func scan(pid: pid_t) -> [AXUIElement] {
    guard let create = createWithRemoteToken else { return [] }
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
    var windows: [AXUIElement] = []
    for number in 0..<scanLimit {
      token.replaceSubrange(12..<20, with: withUnsafeBytes(of: number) { Data($0) })
      guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
      var role: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
        role as? String == kAXWindowRole as String
      {
        windows.append(element)
      }
    }
    return windows
  }
}

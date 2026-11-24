// Development helper for scripts/devenv: presses Microsoft Teams buttons by label and reports
// meeting state through Accessibility, the same way TeamsMuteReader reads it. Like the app, it
// first refreshes every window's Accessibility tree, which Teams leaves stale while a window is
// minimized, covered or on another desktop; add --stale to read the trees as they are.
//   teams-control press <regex>   Press the first button whose label matches.
//   teams-control find <regex>    Exit 0 if such a button exists, without pressing it.
//   Add --meeting to press/find to search only meeting windows (those with a Leave button).
//   teams-control buttons         Print every button label in every Teams window.
//   teams-control windows         Print each window's mic button labels and whether Teams is in front.
//   teams-control speaking        Print each window's framed tiles (hand and speaking frames)
//                                 and speaking labels.
//   teams-control raise <window>  Bring Teams to the front with a window, e.g. the main window
//                                 over the meeting, as when someone works in Teams chat during
//                                 a call. <window> is --meeting (the meeting window, not its
//                                 compact view), --compact, --main or a title regex.
//   teams-control has <window>    Exit 0 if a Teams window on this desktop matches <window>.
//   Add --all-desktops to include Teams windows on other desktops, which macOS does not list;
//   raising one of them moves to its desktop.
//   teams-control minimize <window> [off]
//                                 Minimize (or restore) the first matching Teams window.
//   teams-control cover <seconds> Show an opaque window of this tool over the whole screen, as a
//                                 maximized app covering Teams; Teams stops updating covered
//                                 windows and opens its compact view.
//   teams-control fullscreen <window> [off]
//                                 Put the first matching Teams window in full screen, on a
//                                 desktop of its own, or every matching one back.
//   teams-control language <name> Set Teams' app language to <name> as Teams lists it, e.g.
//                                 "Deutsch (Deutschland)"; Teams restarts when it changes.
//   teams-control slider <regex> [value]
//                                 Print or set the value of a matching slider (e.g. speaker volume).
//   teams-control status-menu <bundle-id> [regex]
//                                 Open an app's menu bar extra; list its items or press a match.
import AppKit
import ApplicationServices

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value as? T
}

let controlRoles: Set<String> = [
  kAXButtonRole, kAXCheckBoxRole, kAXMenuItemRole, kAXMenuButtonRole, kAXPopUpButtonRole,
  kAXRadioButtonRole, "AXTab",
]

func childText(_ element: AXUIElement, depth: Int = 0) -> String? {
  guard depth < 4, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else {
    return nil
  }
  let parts = children.compactMap { child -> String? in
    if let role: String = attribute(child, kAXRoleAttribute), role == kAXStaticTextRole as String {
      return attribute(child, kAXValueAttribute)
    }
    return childText(child, depth: depth + 1)
  }
  return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

func buttons(in window: AXUIElement) -> [(AXUIElement, [String])] {
  var pending = [window]
  var found: [(AXUIElement, [String])] = []
  var visited = 0
  while let element = pending.popLast(), visited < 6_000 {
    visited += 1
    if let role: String = attribute(element, kAXRoleAttribute), controlRoles.contains(role) {
      var labels: [String] = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
        .compactMap { attribute(element, $0) }.filter { !$0.isEmpty }
      // Web buttons such as the lobby's Admit often carry their label only in child text.
      if labels.isEmpty, let text = childText(element), !text.isEmpty { labels = [text] }
      if !labels.isEmpty { found.append((element, labels)) }
    }
    if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
      pending.append(contentsOf: children)
    }
  }
  return found
}

let usage =
  "Usage: teams-control buttons | windows | speaking | has <window> | raise <window> | minimize <window> [off] | fullscreen <window> [off] | cover <seconds> | find|press <regex> [--meeting] | language <name> | slider <regex> [value] | status-menu <bundle-id> [regex] [--stale] [--all-desktops]\n"
if CommandLine.arguments.contains("--help") {
  print(usage, terminator: "")
  exit(0)
}
guard AXIsProcessTrusted() else {
  FileHandle.standardError.write(Data("Accessibility access is required.\n".utf8))
  exit(3)
}
let refreshes = !CommandLine.arguments.contains("--stale")
let allDesktops = CommandLine.arguments.contains("--all-desktops")
let arguments = CommandLine.arguments.dropFirst().filter {
  $0 != "--stale" && $0 != "--all-desktops"
}[...]

if arguments.first == "cover", arguments.count == 2, let seconds = Double(arguments.last!) {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let window = NSWindow(
    contentRect: NSScreen.main!.visibleFrame, styleMask: [.titled], backing: .buffered,
    defer: false)
  window.title = "Cover"
  window.isOpaque = true
  window.backgroundColor = .white
  window.makeKeyAndOrderFront(nil)
  // macOS may refuse to activate this tool while Teams is active; the window still goes on top.
  window.orderFrontRegardless()
  app.activate()
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
  app.run()
}

if arguments.first == "status-menu", arguments.count >= 2 {
  let bundle = arguments[arguments.startIndex + 1]
  guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
  else {
    FileHandle.standardError.write(Data("\(bundle) is not running.\n".utf8))
    exit(4)
  }
  let element = AXUIElementCreateApplication(target.processIdentifier)
  guard let bar: AXUIElement = attribute(element, kAXExtrasMenuBarAttribute),
    let item = (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?)?.first
  else {
    FileHandle.standardError.write(Data("\(bundle) has no menu bar extra.\n".utf8))
    exit(1)
  }
  AXUIElementPerformAction(item, kAXPressAction as CFString)
  Thread.sleep(forTimeInterval: 0.6)
  let menu = (attribute(item, kAXChildrenAttribute) as [AXUIElement]?)?.first
  let entries = (menu.flatMap { attribute($0, kAXChildrenAttribute) } as [AXUIElement]?) ?? []
  let pattern = arguments.count > 2 ? try NSRegularExpression(pattern: arguments.last!) : nil
  for entry in entries {
    let title: String = attribute(entry, kAXTitleAttribute) ?? ""
    if let pattern,
      pattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    {
      AXUIElementPerformAction(entry, kAXPressAction as CFString)
      print("Pressed: \(title)")
      exit(0)
    }
    if pattern == nil, !title.isEmpty {
      let enabled: Bool = attribute(entry, kAXEnabledAttribute) ?? true
      let mark: String = attribute(entry, "AXMenuItemMarkChar") ?? " "
      print("\(mark) \(title)\(enabled ? "" : " (disabled)")")
    }
  }
  AXUIElementPerformAction(menu ?? item, kAXCancelAction as CFString)
  exit(pattern == nil ? 0 : 1)
}

guard
  let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2")
    .first
else {
  FileHandle.standardError.write(Data("Teams is not running.\n".utf8))
  exit(4)
}
let application = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(application, 1)
_ = AXUIElementSetAttributeValue(
  application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
let listedWindows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []

/// Teams' windows on every desktop: macOS lists only the current desktop's, so the others are
/// found by their remote tokens, as the app does. Windows Teams keeps without showing them are
/// not standard windows and stay out, as in the app.
func windowsOnAllDesktops() -> [AXUIElement] {
  typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
  guard
    let symbol = dlsym(
      UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken")
  else { return listedWindows }
  let create = unsafeBitCast(symbol, to: CreateWithRemoteToken.self)
  var token = Data(count: 20)
  token.replaceSubrange(0..<4, with: withUnsafeBytes(of: app.processIdentifier) { Data($0) })
  token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
  var found = listedWindows
  for number: UInt64 in 0..<20_000 {
    token.replaceSubrange(12..<20, with: withUnsafeBytes(of: number) { Data($0) })
    guard let element = create(token as CFData)?.takeRetainedValue(),
      attribute(element, kAXRoleAttribute) == kAXWindowRole as String,
      attribute(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
      !found.contains(where: { CFEqual($0, element) })
    else { continue }
    found.append(element)
  }
  return found
}
let windows = allDesktops ? windowsOnAllDesktops() : listedWindows

/// Scrolling a window's outermost web area into view, which it already is, makes Teams publish
/// its current Accessibility tree.
func refresh(_ window: AXUIElement) {
  var queue = [window]
  var visited = 0
  while !queue.isEmpty, visited < 400 {
    let element = queue.removeFirst()
    visited += 1
    if attribute(element, kAXRoleAttribute) == "AXWebArea" {
      AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
      return
    }
    queue.append(contentsOf: attribute(element, kAXChildrenAttribute) ?? [])
  }
}
if refreshes { windows.forEach(refresh) }

func title(_ window: AXUIElement, matches pattern: String) -> Bool {
  let title: String = attribute(window, kAXTitleAttribute) ?? ""
  return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

/// `--meeting` is the meeting window (with a Leave button, not its compact view), `--compact`
/// the compact view, `--main` Teams' main window (chat, activity, settings); anything else is a
/// regular expression for the title. These work in every Teams language.
func matches(_ window: AXUIElement, _ selector: String) throws -> Bool {
  let compact = title(window, matches: "^(Meeting compact view|Kompakte Besprechungsansicht) \\|")
  let meeting = {
    buttons(in: window).contains { _, labels in
      labels.contains { $0 == "Leave" || $0 == "Verlassen" }
    }
  }
  switch selector {
  case "--meeting": return !compact && meeting()
  case "--compact": return compact
  case "--main":
    return !compact && !title(window, matches: "^(Pinned window|Fixiertes Fenster)$") && !meeting()
  default:
    _ = try NSRegularExpression(pattern: selector)
    return title(window, matches: selector)
  }
}

/// The first element of one of `roles` whose title, description or text value matches, in
/// `searched` windows or all of them.
func element(_ roles: Set<String>, _ pattern: String, in searched: [AXUIElement]? = nil)
  -> AXUIElement?
{
  let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
  for window in searched ?? windows {
    var pending = [window]
    var visited = 0
    while let element = pending.popLast(), visited < 20_000 {
      visited += 1
      if let role: String = attribute(element, kAXRoleAttribute), roles.contains(role) {
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
          .compactMap { attribute(element, $0) as String? }
        if labels.contains(where: {
          expression?.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }) {
          return element
        }
      }
      pending.append(contentsOf: attribute(element, kAXChildrenAttribute) ?? [])
    }
  }
  return nil
}

func waitFor(
  _ roles: Set<String>, _ pattern: String, in searched: [AXUIElement]? = nil,
  seconds: Double = 10
) throws -> AXUIElement {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if let found = element(roles, pattern, in: searched) { return found }
    Thread.sleep(forTimeInterval: 0.5)
  }
  throw ControlError.missing(pattern)
}

enum ControlError: Error, CustomStringConvertible {
  case missing(String)
  var description: String {
    switch self {
    case .missing(let pattern): "Teams shows nothing matching \(pattern)."
    }
  }
}

/// Picks `language` (as Teams lists it, e.g. "Deutsch (Deutschland)") as Teams' app language
/// in Settings > General and saves, which restarts Teams. Returns false when it is already set.
/// Opens Teams' settings in the window with the app bar, not in a window a call left behind,
/// and picks `language`.
func changeLanguage(to language: String) throws -> Bool {
  guard
    let main = windows.first(where: {
      element(controlRoles, "^(Activity|Aktivität)$", in: [$0]) != nil
    })
  else { throw ControlError.missing("^(Activity|Aktivität)$") }
  let searched = [main]
  let comboBox: Set<String> = [kAXComboBoxRole as String]
  let appLanguage = "^(App language|App-Sprache)$"
  if element(comboBox, appLanguage, in: searched) == nil {
    app.activate()
    AXUIElementPerformAction(main, kAXRaiseAction as CFString)
    AXUIElementPerformAction(
      try waitFor(controlRoles, "^(Settings and more|Einstellungen und mehr)", in: searched),
      kAXPressAction as CFString)
    AXUIElementPerformAction(
      try waitFor([kAXMenuItemRole as String], "^(Settings|Einstellungen)$", in: searched),
      kAXPressAction as CFString)
    AXUIElementPerformAction(
      try waitFor([kAXRadioButtonRole as String], "^(General|Allgemein)$", in: searched),
      kAXPressAction as CFString)
  }
  let current = try waitFor(comboBox, appLanguage, in: searched)
  if attribute(current, kAXValueAttribute) == language { return false }
  // While Teams follows the system language, the app language list is disabled.
  let followSystem = try waitFor(
    [kAXCheckBoxRole as String], "^(Follow OS settings|Betriebssystemeinstellungen folgen)$",
    in: searched)
  if (attribute(followSystem, kAXValueAttribute) as NSNumber?)?.boolValue == true {
    AXUIElementPerformAction(followSystem, kAXPressAction as CFString)
  }
  AXUIElementPerformAction(
    try waitFor([kAXButtonRole as String], "^Open (App language|App-Sprache)$", in: searched),
    kAXPressAction as CFString)
  let escaped = NSRegularExpression.escapedPattern(for: language)
  AXUIElementPerformAction(
    try waitFor([kAXStaticTextRole as String], "^\(escaped)$", in: searched),
    kAXPressAction as CFString)
  AXUIElementPerformAction(
    try waitFor(
      [kAXButtonRole as String], "^(Save and restart|Speichern und neu starten)$", in: searched),
    kAXPressAction as CFString)
  return true
}

switch arguments.first {
case "buttons":
  for window in windows {
    print("# \(attribute(window, kAXTitleAttribute) as String? ?? "")")
    for (_, labels) in buttons(in: window) { print("  " + labels.joined(separator: " | ")) }
  }
case "windows":
  let frontmost: Bool = attribute(application, kAXFrontmostAttribute) ?? false
  let microphone = try NSRegularExpression(
    pattern: "^(Unmute mic|Mute mic|Mikrofon wieder aktivieren|Mikrofon stummschalten)",
    options: .caseInsensitive)
  print("frontmost=\(frontmost)")
  for window in windows {
    let title: String = attribute(window, kAXTitleAttribute) ?? ""
    let main: Bool = attribute(window, kAXMainAttribute) ?? false
    let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
    let labels = buttons(in: window).flatMap(\.1).filter {
      microphone.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
    }
    print("main=\(main) minimized=\(minimized) mic=\(labels) title=\(title)")
  }
case "speaking":
  // Per window: each tile's frames ("hand raised" tiles keep one frame for the hand, so they
  // speak with two) and "… is speaking" labels.
  for window in windows {
    var frames: [(tile: String, count: Int)] = []
    var labels: [String] = []
    var pending: [(AXUIElement, String?)] = [(window, nil)]
    var visited = 0
    while let (element, enclosing) = pending.popLast(), visited < 6_000 {
      visited += 1
      let role: String = attribute(element, kAXRoleAttribute) ?? ""
      let text: String = attribute(element, kAXDescriptionAttribute) ?? ""
      var tile = enclosing
      if role == "AXMenuItem" || role == "AXImage", !text.isEmpty { tile = text }
      if role == "AXGroup", let classes: [String] = attribute(element, "AXDOMClassList"),
        classes.contains("vdi-frame-occlusion")
      {
        let name = String((tile ?? "?").prefix(70))
        if let index = frames.lastIndex(where: { $0.tile == name }) {
          frames[index].count += 1
        } else {
          frames.append((name, 1))
        }
      }
      if role == "AXGroup", text.hasSuffix("is speaking") || text.hasSuffix("spricht") {
        labels.append(text)
      }
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children.reversed().map { ($0, tile) })
      }
    }
    let title: String = attribute(window, kAXTitleAttribute) ?? ""
    let main: Bool = attribute(window, kAXMainAttribute) ?? false
    print("\(title.prefix(40)) main=\(main) labels=\(labels)")
    for (tile, count) in frames { print("  \(count) frame\(count == 1 ? "" : "s"): \(tile)") }
  }
case "has" where arguments.count == 2:
  exit(try windows.contains { try matches($0, arguments.last!) } ? 0 : 1)
case "raise" where arguments.count == 2:
  let selector = arguments.last!
  for window in windows where try matches(window, selector) {
    let title: String = attribute(window, kAXTitleAttribute) ?? ""
    app.activate()
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    print("Raised: \(title)")
    exit(0)
  }
  FileHandle.standardError.write(Data("No Teams window matches \(selector).\n".utf8))
  exit(1)
case "minimize" where (2...3).contains(arguments.count):
  let selector = arguments[arguments.startIndex + 1]
  let minimize = arguments.last != "off"
  for window in windows where try matches(window, selector) {
    let title: String = attribute(window, kAXTitleAttribute) ?? ""
    AXUIElementSetAttributeValue(
      window, kAXMinimizedAttribute as CFString, (minimize ? kCFBooleanTrue : kCFBooleanFalse)!)
    print("\(minimize ? "Minimized" : "Restored"): \(title)")
    exit(0)
  }
  FileHandle.standardError.write(Data("No Teams window matches \(selector).\n".utf8))
  exit(1)
case "language" where arguments.count == 2:
  let wanted = arguments.last!
  do {
    let changed = try changeLanguage(to: wanted)
    print(changed ? "Teams restarts in \(wanted)." : "Teams already uses \(wanted).")
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
  }
case "fullscreen" where (2...3).contains(arguments.count):
  let selector = arguments[arguments.startIndex + 1]
  let fullScreen = arguments.last != "off"
  var changed = false
  // "off" leaves full screen in every matching window, so `fullscreen . off` tidies up.
  for window in windows where try matches(window, selector) {
    let title: String = attribute(window, kAXTitleAttribute) ?? ""
    AXUIElementSetAttributeValue(
      window, "AXFullScreen" as CFString, (fullScreen ? kCFBooleanTrue : kCFBooleanFalse)!)
    print("\(fullScreen ? "Full screen" : "Windowed"): \(title)")
    changed = true
    if fullScreen { break }
  }
  if !changed {
    FileHandle.standardError.write(Data("No Teams window matches \(selector).\n".utf8))
    exit(1)
  }
case "slider" where arguments.count >= 2:
  let pattern = try NSRegularExpression(
    pattern: arguments[arguments.startIndex + 1], options: .caseInsensitive)
  for window in windows {
    var pending = [window]
    while let element = pending.popLast() {
      if let role: String = attribute(element, kAXRoleAttribute), role == kAXSliderRole as String {
        let label: String = attribute(element, kAXDescriptionAttribute) ?? ""
        if pattern.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
          if arguments.count == 3, let value = Double(arguments.last!) {
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFNumber)
          }
          let value: NSNumber? = attribute(element, kAXValueAttribute)
          print("\(label): \(value?.stringValue ?? "?")")
          exit(0)
        }
      }
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children)
      }
    }
  }
  FileHandle.standardError.write(Data("No Teams slider matches.\n".utf8))
  exit(1)
case "press" where (2...3).contains(arguments.count),
  "find" where (2...3).contains(arguments.count):
  let press = arguments.first == "press"
  let meetingOnly = arguments.count == 3 && arguments.last == "--meeting"
  let source = arguments[arguments.startIndex + 1]
  let pattern = try NSRegularExpression(pattern: source, options: .caseInsensitive)
  let leave = try NSRegularExpression(pattern: "^(Leave|Verlassen)$")
  for window in windows {
    let controls = buttons(in: window)
    if meetingOnly,
      !controls.contains(where: { _, labels in
        labels.contains {
          leave.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
      })
    {
      continue
    }
    for (element, labels) in controls {
      let match = labels.contains {
        pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
      }
      guard match else { continue }
      if !press {
        print("Found: \(labels.joined(separator: " | "))")
        exit(0)
      }
      if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        print("Pressed: \(labels.joined(separator: " | "))")
        exit(0)
      }
    }
  }
  FileHandle.standardError.write(Data("No Teams button matches \(source).\n".utf8))
  exit(1)
default:
  FileHandle.standardError.write(Data(usage.utf8))
  exit(2)
}

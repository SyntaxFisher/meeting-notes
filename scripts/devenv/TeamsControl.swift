// Development helper for scripts/devenv: presses Microsoft Teams buttons by label and reports
// meeting state through Accessibility, the same way TeamsMuteReader reads it.
//   teams-control press <regex>   Press the first button whose label matches.
//   teams-control find <regex>    Exit 0 if such a button exists, without pressing it.
//   Add --meeting to press/find to search only meeting windows (those with a Leave button).
//   teams-control buttons         Print every button label in every Teams window.
//   teams-control windows         Print each window's mic button labels and whether Teams is in front.
//   teams-control speaking        Print each window's tiles framed as speaking and speaking labels.
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

guard AXIsProcessTrusted() else {
  FileHandle.standardError.write(Data("Accessibility access is required.\n".utf8))
  exit(3)
}
let arguments = CommandLine.arguments.dropFirst()

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
let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []

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
  // Tiles Teams frames as the active speaker, and "… is speaking" labels, per window.
  for window in windows {
    var framed: [String] = []
    var labels: [String] = []
    var pending = [window]
    var visited = 0
    while let element = pending.popLast(), visited < 6_000 {
      visited += 1
      let role: String = attribute(element, kAXRoleAttribute) ?? ""
      let text: String = attribute(element, kAXDescriptionAttribute) ?? ""
      if role == "AXGroup", let classes: [String] = attribute(element, "AXDOMClassList"),
        classes.contains("vdi-frame-occlusion")
      {
        framed.append(text.isEmpty ? childText(element) ?? "?" : text)
      }
      if role == "AXGroup", text.hasSuffix("is speaking") || text.hasSuffix("spricht") {
        labels.append(text)
      }
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children)
      }
    }
    let title: String = attribute(window, kAXTitleAttribute) ?? ""
    print("\(title.prefix(40)) framed=\(framed.map { String($0.prefix(40)) }) labels=\(labels)")
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
  let usage =
    "Usage: teams-control buttons | windows | speaking | find|press <regex> [--meeting] | slider <regex> [value]\n"
  FileHandle.standardError.write(Data(usage.utf8))
  exit(2)
}

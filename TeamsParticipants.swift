import AppKit
import ApplicationServices

/// One participant as Teams' Accessibility tree describes them at one moment.
struct TeamsParticipantSighting: Equatable {
  enum Source: String, Codable { case roster, tile, notice }

  let name: String
  var tag: String? = nil
  var role: String? = nil
  var muted: Bool? = nil
  var isLocal = false
  var joined = false
  var left = false
  let source: Source
}

/// Recognizes participant descriptions in the Teams meeting window. The People pane lists
/// every participant with role and mute state ("Anna Schmidt (Unverified), Meeting guest,
/// Unmuted"); video tiles list visible participants ("Sam Carter (Guest), Context menu is
/// available", "Myself video, Jona Bihl, Muted, Has context menu"); transient notices announce
/// joins ("Sam Carter joined the call"). Teams does not expose who is speaking.
enum TeamsParticipantParser {
  private static let roles: [String: String] = [
    "organizer": "Organizer", "co-organizer": "Co-organizer", "presenter": "Presenter",
    "attendee": "Attendee", "meeting guest": "Meeting guest", "guest": "Guest",
    "organisator": "Organizer", "mitorganisator": "Co-organizer", "referent": "Presenter",
    "teilnehmer": "Attendee", "besprechungsgast": "Meeting guest", "gast": "Guest",
  ]
  private static let tags: Set<String> = [
    "unverified", "guest", "external", "nicht überprüft", "gast", "extern",
  ]
  private static let muteWords: [String: Bool] = [
    "muted": true, "unmuted": false, "stummgeschaltet": true, "stummschaltung aufgehoben": false,
  ]
  private static let tileSuffixes: Set<String> = [
    "context menu is available", "has context menu", "kontextmenü ist verfügbar",
    "hat kontextmenü",
  ]
  private static let localPrefixes = ["Myself video, ", "Eigenes Video, "]
  private static let joinSuffixes = [" joined the call", " ist dem Anruf beigetreten"]
  private static let leaveSuffixes = [" left the call", " hat den Anruf verlassen"]

  /// A People pane section header such as "In this meeting, 4 total". Returns whether the
  /// rows that follow are in the meeting; lobby, invited and suggested people are not.
  static func section(_ description: String) -> Bool? {
    guard
      let match = description.firstMatch(
        of: #/^(.+?), \d+ (?:total|insgesamt)\b/#.ignoresCase())
    else { return nil }
    let title = match.1.lowercased()
    let absent = ["lobby", "wartebereich", "warte", "invited", "eingeladen", "suggest", "vorschl"]
    return !absent.contains { title.contains($0) }
  }

  static func parse(role axRole: String, description: String) -> TeamsParticipantSighting? {
    let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 200 else { return nil }
    switch axRole {
    case "AXRow", "AXGroup": return rosterEntry(text)
    case "AXMenuItem", "AXImage": return tile(text)
    case "AXStaticText": return notice(text)
    default: return nil
    }
  }

  private static func rosterEntry(_ text: String) -> TeamsParticipantSighting? {
    var parts = components(text)
    var muted: Bool?
    if let last = parts.last, let value = muteWords[last.lowercased()] {
      muted = value
      parts.removeLast()
    }
    guard parts.count >= 2, let role = roles[parts.last!.lowercased()] else { return nil }
    parts.removeLast()
    let (name, tag) = splitTag(parts.joined(separator: ", "))
    guard isName(name) else { return nil }
    return TeamsParticipantSighting(name: name, tag: tag, role: role, muted: muted, source: .roster)
  }

  private static func tile(_ text: String) -> TeamsParticipantSighting? {
    var body = text
    var isLocal = false
    for prefix in localPrefixes where body.hasPrefix(prefix) {
      body.removeFirst(prefix.count)
      isLocal = true
    }
    var parts = components(body)
    guard let last = parts.last, tileSuffixes.contains(last.lowercased()) else { return nil }
    parts.removeLast()
    var muted: Bool?
    if let last = parts.last, let value = muteWords[last.lowercased()] {
      muted = value
      parts.removeLast()
    }
    let (name, tag) = splitTag(parts.joined(separator: ", "))
    guard isName(name) else { return nil }
    return TeamsParticipantSighting(
      name: name, tag: tag, muted: muted, isLocal: isLocal, source: .tile)
  }

  private static func notice(_ text: String) -> TeamsParticipantSighting? {
    for suffix in joinSuffixes where text.hasSuffix(suffix) {
      let (name, tag) = splitTag(String(text.dropLast(suffix.count)))
      guard isName(name) else { return nil }
      return TeamsParticipantSighting(name: name, tag: tag, joined: true, source: .notice)
    }
    for suffix in leaveSuffixes where text.hasSuffix(suffix) {
      let (name, tag) = splitTag(String(text.dropLast(suffix.count)))
      guard isName(name) else { return nil }
      return TeamsParticipantSighting(name: name, tag: tag, left: true, source: .notice)
    }
    return nil
  }

  /// Rejects counts and groups such as "2 participants" (an aggregated join notice or a gallery
  /// overflow tile) and "Anna Schmidt and Sam Carter".
  private static func isName(_ name: String) -> Bool {
    guard let first = name.first, !first.isNumber, first != "+" else { return false }
    return name.range(of: #" (?:and|und) "#, options: .regularExpression) == nil
  }

  private static func components(_ text: String) -> [String] {
    text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func splitTag(_ text: String) -> (String, String?) {
    let name = text.trimmingCharacters(in: .whitespaces)
    guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return (name, nil) }
    let tag = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
    guard tags.contains(tag.lowercased()) else { return (name, nil) }
    return (String(name[..<open]).trimmingCharacters(in: .whitespaces), tag)
  }
}

/// Participants seen during one recording. Times are seconds since the recording started.
struct ParticipantRoster: Codable, Equatable {
  struct Participant: Codable, Equatable {
    var name: String
    var tag: String?
    var role: String?
    var isLocal: Bool
    var firstSeen: Double
    var lastSeen: Double
    var joinedAt: Double?
    var leftAt: Double?
    var sources: [TeamsParticipantSighting.Source]
  }

  var participants: [Participant] = []
  /// Whether the People pane was open at least once, so the list may include participants
  /// without a visible video tile.
  var sawFullRoster = false

  var localParticipant: Participant? { participants.first { $0.isLocal } }
  var remoteParticipants: [Participant] { participants.filter { !$0.isLocal } }

  /// Merges one Accessibility snapshot. Returns whether anything changed.
  @discardableResult
  mutating func observe(_ sightings: [TeamsParticipantSighting], at time: Double) -> Bool {
    let before = self
    let localNames = Set(sightings.filter(\.isLocal).map { Self.key($0.name) })
    if sightings.contains(where: { $0.source == .roster }) { sawFullRoster = true }
    for sighting in sightings {
      let key = Self.key(sighting.name)
      let index =
        participants.firstIndex { Self.key($0.name) == key }
        ?? {
          participants.append(
            Participant(
              name: sighting.name, isLocal: false, firstSeen: time, lastSeen: time,
              sources: []))
          return participants.count - 1
        }()
      var participant = participants[index]
      participant.lastSeen = max(participant.lastSeen, time)
      if participant.tag == nil { participant.tag = sighting.tag }
      if let role = sighting.role { participant.role = role }
      if sighting.isLocal || localNames.contains(key) { participant.isLocal = true }
      if sighting.joined, participant.joinedAt == nil { participant.joinedAt = time }
      if sighting.left { participant.leftAt = time }
      if !participant.sources.contains(sighting.source) {
        participant.sources.append(sighting.source)
      }
      participants[index] = participant
    }
    return self != before
  }

  private static func key(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

enum TeamsParticipantReader {
  /// Reads participant descriptions from the single Teams meeting window without changing the
  /// Teams interface. Returns nil when no single meeting window can be read.
  static func read() -> [TeamsParticipantSighting]? {
    guard AXIsProcessTrusted() else { return nil }
    let apps = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.microsoft.teams2")
    guard apps.count == 1, let app = apps.first else { return nil }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.5)
    _ = AXUIElementSetAttributeValue(
      application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    guard let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) else {
      return nil
    }
    var meetings: [[TeamsParticipantSighting]] = []
    for window in windows {
      var pending: [AXUIElement] = [window]
      var sightings: [TeamsParticipantSighting] = []
      var isMeeting = false
      var inMeetingSection = true
      var visited = 0
      while let element = pending.popLast(), visited < 6_000 {
        visited += 1
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        if role == kAXButtonRole as String,
          let title: String = attribute(element, kAXTitleAttribute)
            ?? attribute(
              element, kAXDescriptionAttribute),
          title.range(of: #"^(?:Leave|Verlassen)\b"#, options: .regularExpression) != nil
        {
          isMeeting = true
        }
        if ["AXRow", "AXGroup", "AXMenuItem", "AXImage", "AXStaticText"].contains(role),
          let text = [kAXDescriptionAttribute, kAXValueAttribute].lazy.compactMap({
            (name: String) -> String? in attribute(element, name)
          }).first(where: { !$0.isEmpty })
        {
          if let present = TeamsParticipantParser.section(text) {
            inMeetingSection = present
          } else if let sighting = TeamsParticipantParser.parse(role: role, description: text),
            sighting.source != .roster || inMeetingSection
          {
            sightings.append(sighting)
          }
        }
        // Children are visited in document order, so section headers precede their rows.
        if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
          pending.append(contentsOf: children.reversed())
        }
      }
      if isMeeting { meetings.append(sightings) }
    }
    return meetings.count == 1 ? meetings[0] : nil
  }

  private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }
}

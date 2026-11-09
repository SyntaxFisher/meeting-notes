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
/// joins ("Sam Carter joined the call").
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
  /// States Teams appends to a tile's name, such as "Muster, Léa (Design), Video ist ein,
  /// Hat die Kontrolle über Produktionstools, Kontextmenü ist verfügbar".
  private static let tileStates: Set<String> = [
    "video is on", "video is off", "has control of production tools", "fill frame",
    "fit to frame", "pinned", "spotlighted", "hand raised", "video ist ein",
    "video deaktiviert", "hat die kontrolle über produktionstools", "frame ausfüllen",
    "an frame anpassen", "angeheftet", "im spotlight", "hand erhoben",
  ]
  private static let localPrefixes = [
    "Myself video, ", "Video von mir selbst, ", "Eigenes Video, ",
  ]
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
    let parts = components(body)
    guard let last = parts.last, tileSuffixes.contains(last.lowercased()) else { return nil }
    let states = parts.dropLast()
    let nameParts = states.prefix {
      muteWords[$0.lowercased()] == nil && !tileStates.contains($0.lowercased())
    }
    let muted = states.dropFirst(nameParts.count).lazy.compactMap { muteWords[$0.lowercased()] }
      .first
    let (name, tag) = splitTag(nameParts.joined(separator: ", "))
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

  static func splitTag(_ text: String) -> (String, String?) {
    let name = text.trimmingCharacters(in: .whitespaces)
    guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return (name, nil) }
    let tag = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
    guard tags.contains(tag.lowercased()) else { return (name, nil) }
    return (String(name[..<open]).trimmingCharacters(in: .whitespaces), tag)
  }
}

/// Who Teams shows as speaking. Teams draws a frame around the active speaker's video tile
/// (`vdi-frame-occlusion`, the gallery while the meeting window is in front) and labels the
/// compact meeting view it opens when another app is in front ("Anna Schmidt (Guest) is
/// speaking", "Niemand spricht."). Both stay readable through Accessibility while the meeting
/// is minimized or Teams is in the background. Teams highlights the voice it hears, so the label
/// trails speech by a second or two and briefly misses rapid exchanges.
enum TeamsSpeakingParser {
  static let speakingFrameClass = "vdi-frame-occlusion"
  private static let speakingSuffixes = [" is speaking", " spricht.", " spricht"]
  private static let nobody: Set<String> = [
    "nobody is speaking", "niemand spricht.", "niemand spricht",
  ]
  /// Your own voice is in the microphone track, never in the Teams audio.
  private static let localSpeaking: Set<String> = [
    "you are speaking", "sie sprechen.", "sie sprechen",
  ]
  private static let localPrefixes = ["You and ", "Sie und "]
  private static let localSuffixes = [" are speaking", " sprechen.", " sprechen"]

  enum Label: Equatable {
    case speaking(String)
    case nobody
  }

  /// Parses the compact view's speaker label. Teams fills its "{name} is speaking" template
  /// with whatever it shows for the speaker, so your own turns read "You are speaking is
  /// speaking" and a speaker change briefly reads " is speaking", which returns nil.
  /// "You and Anna are speaking" names Anna; your own speech names no remote voice.
  static func label(_ description: String) -> Label? {
    let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 200 else { return nil }
    if let speaker = speaker(text) { return speaker }
    guard let suffix = speakingSuffixes.first(where: { text.hasSuffix($0) }) else { return nil }
    let filled = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
    if let speaker = speaker(filled) { return speaker }
    let (name, _) = TeamsParticipantParser.splitTag(filled)
    return name.isEmpty ? nil : .speaking(name)
  }

  /// Labels that say who speaks without the template: nobody, you, or you and someone.
  private static func speaker(_ text: String) -> Label? {
    let lowercased = text.lowercased()
    if nobody.contains(lowercased) || localSpeaking.contains(lowercased) { return .nobody }
    for prefix in localPrefixes where text.hasPrefix(prefix) {
      for suffix in localSuffixes where text.hasSuffix(suffix) {
        let (name, _) = TeamsParticipantParser.splitTag(
          String(text.dropFirst(prefix.count).dropLast(suffix.count)))
        return name.isEmpty ? .nobody : .speaking(name)
      }
    }
    return nil
  }
}

/// When Teams showed each remote participant as the active speaker during one recording, in
/// seconds on the host clock that also times the capture tracks (`capture.json`). The
/// transcription helper reads it as `speaking.json` to name remote voices.
struct SpeakingTimeline: Codable, Equatable {
  struct Interval: Codable, Equatable {
    var name: String
    /// The first and last reading that showed `name` as speaking.
    var start: Double
    var end: Double
  }

  var intervals: [Interval] = []
  private var lastReading: (name: String?, time: Double)?

  /// Readings further apart than this do not join: Teams could not be read in between.
  static let maximumGap = 3.0

  enum CodingKeys: String, CodingKey { case intervals }

  init(intervals: [Interval] = []) { self.intervals = intervals }

  static func == (left: SpeakingTimeline, right: SpeakingTimeline) -> Bool {
    left.intervals == right.intervals
  }

  /// Merges one reading at `time`; `speaker` nil means Teams showed nobody speaking. Returns
  /// whether a new interval started.
  @discardableResult
  mutating func observe(_ speaker: String?, at time: Double) -> Bool {
    defer { lastReading = (speaker, time) }
    if let speaker, let last = lastReading, last.name == speaker, time >= last.time,
      time - last.time <= Self.maximumGap, intervals.last?.name == speaker
    {
      intervals[intervals.count - 1].end = time
      return false
    }
    guard let speaker else { return false }
    intervals.append(Interval(name: speaker, start: time, end: time))
    return true
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

/// One Accessibility pass over the Teams windows during a recording.
struct TeamsMeetingSnapshot: Equatable {
  /// Participants in the meeting window; nil when there is no single meeting.
  var participants: [TeamsParticipantSighting]?
  /// Who Teams shows as speaking: a name, `.some(nil)` for nobody, nil when Teams shows no
  /// current speaker indication.
  var speaker: String??
}

enum TeamsParticipantReader {
  /// Reads participant descriptions from the single Teams meeting window without changing the
  /// Teams interface. Returns nil when no single meeting window can be read.
  static func read() -> [TeamsParticipantSighting]? { snapshot()?.participants }

  /// What one Teams window shows, gathered in a single pass.
  struct WindowReading: Equatable {
    var isMeeting = false
    var sightings: [TeamsParticipantSighting] = []
    /// Tiles framed as the active speaker; only collected from a window Teams keeps current.
    var framed: Set<String> = []
    var labels: [TeamsSpeakingParser.Label] = []
  }

  /// Reads participants and the active speaker in one pass over all Teams windows.
  static func snapshot() -> TeamsMeetingSnapshot? {
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
    // A hidden Teams stops updating its windows; a meeting window behind other windows keeps
    // the frame it last drew, so only the frontmost one shows the current speaker.
    let hidden: Bool = attribute(application, kAXHiddenAttribute) ?? false
    let frontmost: Bool = attribute(application, kAXFrontmostAttribute) ?? false
    let readings = windows.map { window in
      read(window, framesAreCurrent: frontmost && (attribute(window, kAXMainAttribute) ?? false))
    }
    return combine(readings, hidden: hidden)
  }

  /// Teams can show one meeting in two windows: the meeting window with participant tiles and,
  /// while another app or Teams view is in front, a compact view whose label names the
  /// speaker. Participants come from the one meeting window that lists any; the compact view's
  /// label wins over a gallery frame.
  static func combine(_ readings: [WindowReading], hidden: Bool) -> TeamsMeetingSnapshot {
    let meetings = readings.filter(\.isMeeting)
    let listing = meetings.filter { !$0.sightings.isEmpty }
    let participants =
      meetings.isEmpty || listing.count > 1 ? nil : (listing.first?.sightings ?? [])
    guard !hidden, !meetings.isEmpty else {
      return TeamsMeetingSnapshot(participants: participants)
    }
    if let label = meetings.lazy.compactMap(\.labels.last).first {
      switch label {
      case .speaking(let name):
        return TeamsMeetingSnapshot(participants: participants, speaker: .some(name))
      case .nobody: return TeamsMeetingSnapshot(participants: participants, speaker: .some(nil))
      }
    }
    let framed = meetings.reduce(into: Set<String>()) { $0.formUnion($1.framed) }
    guard framed.count <= 1 else { return TeamsMeetingSnapshot(participants: participants) }
    return TeamsMeetingSnapshot(participants: participants, speaker: .some(framed.first))
  }

  private static func read(_ window: AXUIElement, framesAreCurrent: Bool) -> WindowReading {
    var reading = WindowReading()
    var pending: [(element: AXUIElement, tile: String?)] = [(window, nil)]
    var inMeetingSection = true
    var visited = 0
    while let (element, enclosingTile) = pending.popLast(), visited < 6_000 {
      visited += 1
      let role: String = attribute(element, kAXRoleAttribute) ?? ""
      var tile = enclosingTile
      if role == kAXButtonRole as String,
        let title: String = attribute(element, kAXTitleAttribute)
          ?? attribute(element, kAXDescriptionAttribute),
        title.range(of: #"^(?:Leave|Verlassen)\b"#, options: .regularExpression) != nil
      {
        reading.isMeeting = true
      }
      if framesAreCurrent, let tile, role == "AXGroup",
        let classes: [String] = attribute(element, "AXDOMClassList"),
        classes.contains(TeamsSpeakingParser.speakingFrameClass)
      {
        reading.framed.insert(tile)
      }
      if ["AXRow", "AXGroup", "AXMenuItem", "AXImage", "AXStaticText"].contains(role),
        let text = [kAXDescriptionAttribute, kAXValueAttribute].lazy.compactMap({
          (name: String) -> String? in attribute(element, name)
        }).first(where: { !$0.isEmpty })
      {
        if let present = TeamsParticipantParser.section(text) {
          inMeetingSection = present
        } else if let sighting = TeamsParticipantParser.parse(role: role, description: text) {
          if sighting.source != .roster || inMeetingSection { reading.sightings.append(sighting) }
          // Your own tile never names a voice in the Teams audio.
          if sighting.source == .tile { tile = sighting.isLocal ? nil : sighting.name }
        } else if role == "AXGroup", let label = TeamsSpeakingParser.label(text) {
          reading.labels.append(label)
        }
      }
      // Children are visited in document order, so section headers precede their rows.
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children.reversed().map { ($0, tile) })
      }
    }
    return reading
  }

  private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }
}

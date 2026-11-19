import AppKit
import ApplicationServices

/// One participant as Teams' Accessibility tree describes them at one moment.
struct TeamsParticipantSighting: Equatable {
  enum Source: String, Codable { case roster, tile, notice }

  let name: String
  var tag: String? = nil
  var role: String? = nil
  var muted: Bool? = nil
  var handRaised = false
  var isLocal = false
  var joined = false
  var left = false
  let source: Source
}

/// Recognizes participant descriptions in the Teams meeting window. The People pane lists
/// every participant with role and mute state ("Anna Schmidt (Unverified), Meeting guest,
/// Unmuted"); video tiles list visible participants ("Sam Carter (Guest), Context menu is
/// available", "Myself video, Jona Bihl, Muted, Has context menu"); transient notices announce
/// joins ("Sam Carter joined the call"). A 1:1 call and the compact meeting view describe a
/// tile with the name alone ("Sam Carter", "Myself video, Jona Bihl"), which only counts on
/// the call stage (`stageTileRole`), where every menu item is a tile.
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
  /// Hat die Kontrolle über Produktionstools, Kontextmenü ist verfügbar", in the wording of
  /// Teams' English and German calling strings. Any other component starting with "Video "
  /// also counts as a camera state (`isTileState`).
  private static let tileStates: Set<String> = [
    "video is on", "video is off", "video reconnecting", "video briefly stopped",
    "camera is on", "camera is off", "has control of production tools", "fill frame",
    "fit to frame", "pinned", "spotlighted", "hand raised", "presenting", "on hold",
    "poor connection", "poor network quality", "connection problem", "connection is weak",
    "connection is unstable",
    "video ist ein", "video deaktiviert", "videoverbindung wird wiederhergestellt",
    "video kurz angehalten", "kamera ist aktiviert.", "kamera ist aus.",
    "hat die kontrolle über produktionstools", "frame ausfüllen", "an frame anpassen",
    "angeheftet", "im spotlight", "hand erhoben", "erhobene hände", "präsentation", "gehalten",
    "warteschleife", "schlechte verbindung", "schlechte netzwerkqualität", "verbindungsproblem",
    "die verbindung ist schwach", "verbindung ist instabil",
  ]
  private static let handRaisedStates: Set<String> = ["hand raised", "hand erhoben"]
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
    case stageTileRole: return tile(text, onStage: true)
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

  /// The role the reader gives a menu item on the call stage.
  static let stageTileRole = "tile"

  private static func tile(_ text: String, onStage: Bool = false) -> TeamsParticipantSighting? {
    var body = text
    var isLocal = false
    for prefix in localPrefixes where body.hasPrefix(prefix) {
      body.removeFirst(prefix.count)
      isLocal = true
    }
    let parts = components(body)
    guard let last = parts.last else { return nil }
    let hasSuffix = tileSuffixes.contains(last.lowercased())
    guard hasSuffix || onStage else { return nil }
    let states = hasSuffix ? parts.dropLast() : parts[...]
    let nameParts = states.prefix { muteWords[$0.lowercased()] == nil && !isTileState($0) }
    let muted = states.dropFirst(nameParts.count).lazy.compactMap { muteWords[$0.lowercased()] }
      .first
    let handRaised = states.contains { handRaisedStates.contains($0.lowercased()) }
    let (name, tag) = splitTag(nameParts.joined(separator: ", "))
    guard isName(name) else { return nil }
    return TeamsParticipantSighting(
      name: name, tag: tag, muted: muted, handRaised: handRaised, isLocal: isLocal, source: .tile)
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

  private static func isTileState(_ component: String) -> Bool {
    let state = component.lowercased()
    return tileStates.contains(state) || state.hasPrefix("video ")
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

/// Who Teams shows as speaking. Teams draws a frame (`vdi-frame-occlusion`) around the active
/// speaker's video tile, and another one of the same kind around a tile with a raised hand,
/// so a tile with a raised hand speaks only while it has a second frame. Teams labels the
/// compact meeting view it opens when the meeting window is minimized or replaced by another
/// Teams view ("Anna Schmidt (Guest) is speaking", "Niemand spricht."). Teams highlights the
/// voice it hears, so the label trails speech by a second or two and briefly misses rapid
/// exchanges.
///
/// Teams stops updating a window macOS reports as not visible: minimized, on another desktop,
/// or completely covered by other apps' windows; Teams' own windows do not count. Such a
/// window keeps showing its last state, frames included, for as long as it stays hidden, and
/// Teams opens the compact view, which follows the call, while the meeting window is hidden
/// (`TeamsWindowVisibility`).
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

/// Whether macOS shows a Teams window, from the on-screen window list (front to back, in the
/// global top-left coordinates Accessibility uses). Only other apps' ordinary windows cover a
/// window; system overlays such as the Dock's span the screen without hiding anything.
enum TeamsWindowOcclusion {
  struct Window: Equatable {
    var owner: pid_t
    var layer: Int
    var frame: CGRect
  }

  static func onScreenWindows() -> [Window] {
    let list =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return list.compactMap { info in
      guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
        let layer = info[kCGWindowLayer as String] as? Int,
        (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds)
      else { return nil }
      return Window(owner: owner, layer: layer, frame: frame)
    }
  }

  /// `frame` is the window's Accessibility frame; a window macOS does not list on screen at
  /// that frame is hidden.
  static func visibility(of frame: CGRect, owner: pid_t, in windows: [Window])
    -> TeamsWindowVisibility
  {
    guard
      let index = windows.firstIndex(where: {
        $0.owner == owner && abs($0.frame.minX - frame.minX) <= 2
          && abs($0.frame.minY - frame.minY) <= 2 && abs($0.frame.width - frame.width) <= 2
          && abs($0.frame.height - frame.height) <= 2
      })
    else { return .hidden }
    var visible = [windows[index].frame]
    for window in windows[..<index] where window.owner != owner && window.layer == 0 {
      visible = visible.flatMap { subtract(window.frame, from: $0) }
      if visible.isEmpty { return .covered }
    }
    return .visible
  }

  /// The parts of `rect` outside `cut`, as up to four rectangles.
  static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
    let overlap = rect.intersection(cut)
    guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
    return [
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
      CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
      CGRect(
        x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
      CGRect(
        x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
    ].filter { $0.width >= 1 && $0.height >= 1 }
  }
}

/// Notices a Teams window whose call clock stopped. A live meeting window advances its clock
/// every second; a window Teams stopped updating keeps the last time. Only a clock seen
/// advancing counts, so another time on screen, such as a chat timestamp, never does.
struct TeamsClockWatch {
  /// Longer than a clock tick plus a slow reading.
  static let stall = 3.0
  private var clocks: [Int: (text: String, since: Double, advanced: Bool)] = [:]

  static func isClock(_ text: String) -> Bool {
    text.range(of: #"^\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
  }

  mutating func isStalled(window: Int, clock: String?, at time: Double) -> Bool {
    guard let clock else {
      clocks[window] = nil
      return false
    }
    guard let last = clocks[window] else {
      clocks[window] = (clock, time, false)
      return false
    }
    if last.text != clock {
      clocks[window] = (clock, time, true)
      return false
    }
    return last.advanced && time - last.since > Self.stall
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

  /// One interval per participant and stretch of readings; intervals of different
  /// participants overlap where Teams framed several tiles at once.
  var intervals: [Interval] = []
  private var lastReading: (names: Set<String>, time: Double)?

  /// Readings further apart than this do not join: Teams could not be read in between.
  static let maximumGap = 3.0

  enum CodingKeys: String, CodingKey { case intervals }

  init(intervals: [Interval] = []) { self.intervals = intervals }

  static func == (left: SpeakingTimeline, right: SpeakingTimeline) -> Bool {
    left.intervals == right.intervals
  }

  /// Merges one reading at `time` of everyone Teams showed speaking; none means nobody.
  /// Returns whether a new interval started.
  @discardableResult
  mutating func observe(_ speakers: [String], at time: Double) -> Bool {
    var names = Set<String>()
    defer { lastReading = (names, time) }
    var started = false
    for name in speakers where names.insert(name).inserted {
      if let last = lastReading, last.names.contains(name), time >= last.time,
        time - last.time <= Self.maximumGap,
        let index = intervals.lastIndex(where: { $0.name == name })
      {
        intervals[index].end = time
      } else {
        intervals.append(Interval(name: name, start: time, end: time))
        started = true
      }
    }
    return started
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

  /// Teams sometimes flattens a guest's changing badge into the tile name. A join notice
  /// supplies the display name independently. Require the notice and first tile in the same
  /// reading, then a switch to the other badge without seeing both tiles together.
  var resolvedTileNames: (roster: ParticipantRoster, aliases: [String: String]) {
    var roster = self
    var aliases: [String: String] = [:]
    for (index, person) in participants.enumerated() {
      guard !person.isLocal, let joined = person.joinedAt, !person.sources.contains(.tile) else {
        continue
      }
      let variants = ["Unverified", "External unfamiliar"].compactMap { badge in
        remoteParticipants.first { $0.name == "\(person.name) \(badge)" && $0.sources == [.tile] }
      }.sorted { $0.firstSeen < $1.firstSeen }
      guard variants.count == 2, variants[0].firstSeen == joined,
        variants[0].lastSeen < variants[1].firstSeen,
        variants[1].firstSeen - variants[0].lastSeen <= 4,
        person.leftAt.map({ $0 >= variants[1].lastSeen }) ?? true
      else { continue }
      for variant in variants { aliases[variant.name] = person.name }
      roster.participants[index].sources.append(.tile)
      roster.participants[index].lastSeen = max(person.lastSeen, variants[1].lastSeen)
    }
    roster.participants.removeAll { aliases[$0.name] != nil }
    return (roster, aliases)
  }

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
  /// Everyone Teams shows as speaking, empty for nobody, nil when Teams shows no current
  /// speaker indication.
  var speakers: [String]?
}

/// One element the participant reader uses, in document order: a button title, a speaking
/// frame inside a participant's tile (`role` "frame", `text` the tile's name), or a text of
/// one of the roles that carry participant, section and speaker labels.
struct TeamsAXItem: Codable, Equatable {
  var role: String
  var text: String
}

/// Whether a Teams window shows the call as it is now. Teams stops updating a `hidden` window
/// (not on screen: minimized, on another desktop, or Teams hidden) and a `covered` one, which
/// other apps' windows cover completely. A `frozen` window's call clock stopped although it
/// ran before, whatever the reason.
enum TeamsWindowVisibility: String, Codable {
  case visible, covered, hidden, frozen
}

/// One Teams window as the participant reader read it: whether it is Teams' main window and
/// how visible it was, nil where not read.
struct TeamsParticipantWindowInput: Codable, Equatable {
  var id: Int
  var title: String?
  var minimized = false
  var main: Bool? = nil
  var visibility: TeamsWindowVisibility? = nil
  var items: [TeamsAXItem] = []
}

/// One participant reading's input, or nil windows when Teams could not be read.
struct TeamsParticipantInput: Codable, Equatable {
  var hidden = false
  var windows: [TeamsParticipantWindowInput]?

  /// The input with only the items the reader recognizes: meeting controls, speaking frames,
  /// section headers, participant descriptions and speaker labels. Chat messages and their
  /// previews, file names and notifications stay out of the trace. Reading the traced input
  /// gives the same snapshot.
  var traced: TeamsParticipantInput {
    var input = self
    input.windows = windows?.map { window in
      var window = window
      window.items = window.items.filter { item in
        switch item.role {
        case "AXButton": return TeamsMuteClassifier.isMeetingControl([item.text])
        case "frame": return true
        default:
          return TeamsParticipantParser.section(item.text) != nil
            || TeamsParticipantParser.parse(role: item.role, description: item.text) != nil
            || (item.role == "AXGroup" && TeamsSpeakingParser.label(item.text) != nil)
        }
      }
      return window
    }
    return input
  }
}

enum TeamsParticipantReader {
  /// Reads participant descriptions from the single Teams meeting window without changing the
  /// Teams interface. Returns nil when no single meeting window can be read.
  static func read() -> [TeamsParticipantSighting]? { snapshot()?.participants }

  /// What one Teams window shows, gathered in a single pass.
  struct WindowReading: Equatable {
    var isMeeting = false
    var isCompactView = false
    var sightings: [TeamsParticipantSighting] = []
    /// Whether the window shows the call as it is now, so its frames tell who speaks.
    var framesAreCurrent = true
    /// Tiles framed as speaking, in document order.
    var framed: [String] = []
    var labels: [TeamsSpeakingParser.Label] = []
  }

  /// Reads participants and the active speaker in one pass over all Teams windows.
  static func snapshot() -> TeamsMeetingSnapshot? {
    let input = self.input()
    TeamsTrace.shared.record("participants-input", value: input.traced)
    let snapshot = self.snapshot(input)
    TeamsTrace.shared.record(
      "participants",
      [
        "count": snapshot?.participants?.count ?? -1,
        "speakers": snapshot?.speakers ?? NSNull(),
      ])
    TeamsTrace.shared.record("participants-read", always: true, [:])
    return snapshot
  }

  /// The snapshot `input` describes.
  static func snapshot(_ input: TeamsParticipantInput) -> TeamsMeetingSnapshot? {
    guard let windows = input.windows else { return nil }
    return combine(
      windows.map {
        var reading = reading(
          $0.items, framesAreCurrent: !$0.minimized && ($0.visibility ?? .visible) == .visible)
        reading.isCompactView = TeamsMuteClassifier.isCompactView($0.title)
        return reading
      }, hidden: input.hidden)
  }

  private static func input() -> TeamsParticipantInput {
    guard AXIsProcessTrusted() else { return TeamsParticipantInput() }
    let apps = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.microsoft.teams2")
    guard apps.count == 1, let app = apps.first else { return TeamsParticipantInput() }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.5)
    _ = AXUIElementSetAttributeValue(
      application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    guard let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) else {
      return TeamsParticipantInput()
    }
    let onScreen = TeamsWindowOcclusion.onScreenWindows()
    let now = ProcessInfo.processInfo.systemUptime
    return TeamsParticipantInput(
      hidden: attribute(application, kAXHiddenAttribute) ?? false,
      windows: windows.map { window in
        let id = TeamsWindowRegistry.shared.id(of: window)
        let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
        let items = items(of: window)
        var visibility =
          minimized
          ? .hidden
          : frame(of: window).map {
            TeamsWindowOcclusion.visibility(of: $0, owner: app.processIdentifier, in: onScreen)
          }
        let clock = items.first { $0.role == "AXStaticText" && TeamsClockWatch.isClock($0.text) }
        if clockWatch.isStalled(window: id, clock: clock?.text, at: now), visibility == .visible {
          visibility = .frozen
        }
        return TeamsParticipantWindowInput(
          id: id, title: attribute(window, kAXTitleAttribute), minimized: minimized,
          main: attribute(window, kAXMainAttribute) ?? false, visibility: visibility,
          items: items)
      })
  }

  /// Read only from the reader's queue.
  nonisolated(unsafe) private static var clockWatch = TeamsClockWatch()

  private static func frame(of window: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard let position: AXValue = attribute(window, kAXPositionAttribute),
      let extent: AXValue = attribute(window, kAXSizeAttribute),
      AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  /// Teams can show one meeting in two windows: the meeting window with participant tiles and,
  /// while another app or Teams view is in front, a compact view whose label names the
  /// speaker. Participants come from the one meeting window that lists any, together with the
  /// compact view, which shows the same meeting; the compact view's label wins over a gallery
  /// frame.
  static func combine(_ readings: [WindowReading], hidden: Bool) -> TeamsMeetingSnapshot {
    let meetings = readings.filter(\.isMeeting)
    let listing = meetings.filter { !$0.sightings.isEmpty }
    let participants =
      meetings.isEmpty || listing.filter({ !$0.isCompactView }).count > 1
      ? nil : listing.flatMap(\.sightings)
    guard !hidden, !meetings.isEmpty else {
      return TeamsMeetingSnapshot(participants: participants)
    }
    if let label = meetings.lazy.compactMap(\.labels.last).first {
      switch label {
      case .speaking(let name):
        return TeamsMeetingSnapshot(participants: participants, speakers: [name])
      case .nobody: return TeamsMeetingSnapshot(participants: participants, speakers: [])
      }
    }
    let current = meetings.filter(\.framesAreCurrent)
    guard !current.isEmpty else { return TeamsMeetingSnapshot(participants: participants) }
    var framed: [String] = []
    for name in current.flatMap(\.framed) where !framed.contains(name) { framed.append(name) }
    return TeamsMeetingSnapshot(participants: participants, speakers: framed)
  }

  static let textRoles: Set<String> = ["AXRow", "AXGroup", "AXMenuItem", "AXImage", "AXStaticText"]

  /// What one window's items show. Children follow their parent in document order, so section
  /// headers precede their rows.
  static func reading(_ items: [TeamsAXItem], framesAreCurrent: Bool) -> WindowReading {
    var reading = WindowReading(framesAreCurrent: framesAreCurrent)
    var inMeetingSection = true
    // The tile whose frames follow, and how many frames it has.
    var tile: (name: String, handRaised: Bool, frames: Int)?
    func closeTile() {
      if let tile, tile.frames > (tile.handRaised ? 1 : 0), !reading.framed.contains(tile.name) {
        reading.framed.append(tile.name)
      }
      tile = nil
    }
    for item in items {
      switch item.role {
      case "AXButton":
        if TeamsMuteClassifier.isMeetingControl([item.text]) { reading.isMeeting = true }
      case "frame":
        if tile?.name != item.text {
          closeTile()
          tile = (item.text, false, 0)
        }
        tile?.frames += 1
      default:
        if let present = TeamsParticipantParser.section(item.text) {
          inMeetingSection = present
        } else if let sighting = TeamsParticipantParser.parse(
          role: item.role, description: item.text)
        {
          if sighting.source != .roster || inMeetingSection { reading.sightings.append(sighting) }
          if sighting.source == .tile, !sighting.isLocal {
            closeTile()
            tile = (sighting.name, sighting.handRaised, 0)
          }
        } else if item.role == "AXGroup", let label = TeamsSpeakingParser.label(item.text) {
          reading.labels.append(label)
        }
      }
    }
    closeTile()
    if !framesAreCurrent { reading.framed = [] }
    return reading
  }

  /// The window's items in document order, with every frame inside a remote participant's
  /// tile; your own tile never names a voice in the Teams audio.
  private static func items(of window: AXUIElement) -> [TeamsAXItem] {
    var items: [TeamsAXItem] = []
    var pending: [(element: AXUIElement, tile: String?, onStage: Bool)] = [(window, nil, false)]
    var visited = 0
    while let (element, enclosingTile, enclosingStage) = pending.popLast(), visited < 6_000 {
      visited += 1
      var role: String = attribute(element, kAXRoleAttribute) ?? ""
      var tile = enclosingTile
      // Teams marks the call stage as the main landmark in every language.
      let onStage =
        enclosingStage
        || (role == "AXGroup" && attribute(element, kAXSubroleAttribute) == "AXLandmarkMain")
      if onStage, role == "AXMenuItem" { role = TeamsParticipantParser.stageTileRole }
      if role == kAXButtonRole as String,
        let title: String = attribute(element, kAXTitleAttribute)
          ?? attribute(element, kAXDescriptionAttribute)
      {
        items.append(TeamsAXItem(role: role, text: title))
      }
      if let tile, role == "AXGroup",
        let classes: [String] = attribute(element, "AXDOMClassList"),
        classes.contains(TeamsSpeakingParser.speakingFrameClass)
      {
        items.append(TeamsAXItem(role: "frame", text: tile))
      }
      if textRoles.contains(role) || role == TeamsParticipantParser.stageTileRole,
        let text = [kAXDescriptionAttribute, kAXValueAttribute].lazy.compactMap({
          (name: String) -> String? in attribute(element, name)
        }).first(where: { !$0.isEmpty })
      {
        items.append(TeamsAXItem(role: role, text: text))
        if TeamsParticipantParser.section(text) == nil,
          let sighting = TeamsParticipantParser.parse(role: role, description: text),
          sighting.source == .tile
        {
          tile = sighting.isLocal ? nil : sighting.name
        }
      }
      if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
        pending.append(contentsOf: children.reversed().map { ($0, tile, onStage) })
      }
    }
    return items
  }

  private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }
}

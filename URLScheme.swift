import Foundation

/// Commands accepted through the `meetingnotes://` URL scheme. Discarding is deliberately not
/// one of them: any local app can open a URL, so deleting work needs the panel, the library,
/// the command line or MCP.
enum URLCommand: Equatable {
  case start(title: String?)
  case stop
  case reveal(id: String?)
  case meeting(MeetingLink)

  static let scheme = "meetingnotes"
  static let usage =
    "Use meetingnotes://meeting/<meeting id>[?p=<passage>|?t=<seconds>], start[?title=…], stop or reveal[?id=…]."

  init?(url: URL) {
    if url.scheme?.lowercased() == "https" {
      guard let link = MeetingLink(url: url) else { return nil }
      self = .meeting(link)
      return
    }
    guard url.scheme?.lowercased() == Self.scheme else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let name = (url.host ?? components?.path ?? "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    func query(_ key: String) -> String? {
      components?.queryItems?.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
    switch name {
    case "start":
      guard components?.queryItems?.contains(where: { $0.name == "source" }) != true else {
        return nil
      }
      self = .start(title: query("title"))
    case "stop": self = .stop
    case "reveal": self = .reveal(id: query("id"))
    case MeetingLink.host:
      guard let link = MeetingLink(url: url) else { return nil }
      self = .meeting(link)
    default: return nil
    }
  }

  var name: String {
    switch self {
    case .start: "start"
    case .stop: "stop"
    case .reveal: "reveal"
    case .meeting: "meeting"
    }
  }

  /// Navigation only shows the app's own window and does not issue recording commands.
  var isNavigation: Bool {
    switch self {
    case .meeting: true
    default: false
    }
  }
}

/// A stable HTTPS link to a local meeting, optionally to a passage or time. Native scheme links
/// remain readable. Both name the exact meeting id, never a prefix or title.
struct MeetingLink: Equatable, Sendable {
  static let host = "meeting"
  static let domain = "meeting-notes.jonabihl.dev"
  static let baseURL = "https://" + domain + "/meeting/"

  var meetingID: String
  /// Seconds from the start of the recording.
  var time: TimeInterval?
  var passageID: String? = nil

  init(meetingID: String, time: TimeInterval? = nil) {
    self.meetingID = meetingID
    self.time = time
  }

  /// The link to a segment carries its start in tenths of a second, which `segmentIndex` maps
  /// back to the same segment.
  init(meetingID: String, segment: MeetingSegment) {
    self.init(meetingID: meetingID, time: Self.tenths(segment.start))
  }

  init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil, components.port == nil,
      components.fragment == nil
    else { return nil }
    let path: String
    switch components.scheme?.lowercased() {
    case "https":
      guard components.host?.lowercased() == Self.domain,
        components.percentEncodedPath.hasPrefix("/meeting/")
      else { return nil }
      let remainder = String(components.percentEncodedPath.dropFirst("/meeting/".count))
      path = remainder.hasSuffix("/") ? String(remainder.dropLast()) : remainder
    case URLCommand.scheme:
      guard components.host?.lowercased() == Self.host else { return nil }
      path = components.percentEncodedPath.trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
    default: return nil
    }
    guard !path.isEmpty, !path.contains("/"), let id = path.removingPercentEncoding,
      !id.contains("/"),
      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let query = components.queryItems ?? []
    guard query.allSatisfy({ ["p", "t"].contains($0.name) }), query.count <= 1 else {
      return nil
    }
    meetingID = id
    time = nil
    if let item = query.first {
      guard let value = item.value else { return nil }
      if item.name == "p" {
        guard value.wholeMatch(of: #/s[1-9][0-9]*/#) != nil,
          Int(value.dropFirst()) != nil
        else { return nil }
        passageID = value
      } else if !value.isEmpty {
        guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
        time = seconds
      }
    }
  }

  func validate(in record: MeetingRecord) throws {
    guard record.id == meetingID else { throw MeetingError("Meeting not found.") }
    if let passageID {
      _ = try record.segmentIndex(for: passageID)
    }
    if let time {
      guard time.isFinite, time >= 0, !Self.isPastEnd(time, of: record) else {
        throw MeetingError("That time is outside this meeting.")
      }
    }
  }

  var url: URL { URL(string: string)! }

  var string: String {
    let id = meetingID.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? meetingID
    var text = Self.baseURL + id
    if let passageID {
      text += "?p=\(passageID)"
    } else if let time {
      text += "?t=\(Self.seconds(time))"
    }
    return text
  }

  /// The segment a time points to: the last one starting at or before it, or the first one
  /// when the time lies before every segment. Starts count in tenths of a second; of segments
  /// starting in the same tenth, as overlapping speakers can, the first one is chosen.
  static func segmentIndex(at time: TimeInterval, in segments: [MeetingSegment]) -> Int? {
    guard !segments.isEmpty else { return nil }
    guard let last = segments.lastIndex(where: { tenths($0.start) <= time }) else { return 0 }
    let start = tenths(segments[last].start)
    return segments.firstIndex { tenths($0.start) == start } ?? last
  }

  /// Whether a time lies beyond the end of the recording and its transcript.
  static func isPastEnd(_ time: TimeInterval, of record: MeetingRecord) -> Bool {
    let end = max(record.durationSeconds ?? 0, record.segments.last?.end ?? 0)
    return time > end.rounded(.up)
  }

  private static let unreserved = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

  private static func tenths(_ seconds: TimeInterval) -> TimeInterval {
    (seconds * 10).rounded(.down) / 10
  }

  private static func seconds(_ time: TimeInterval) -> String {
    let time = tenths(time)
    return String(format: time == time.rounded() ? "%.0f" : "%.1f", time)
  }
}

extension MeetingRecord {
  var link: MeetingLink { MeetingLink(meetingID: id) }

  func link(to segment: MeetingSegment) -> MeetingLink {
    MeetingLink(meetingID: id, segment: segment)
  }
}

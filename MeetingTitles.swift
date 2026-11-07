import Foundation

enum MeetingTitleSource: String, Codable, Sendable {
  case none, teams, agent, user

  static func inferred(title: String?, source: MeetingSource?) -> Self {
    guard MeetingFiles.displayTitle(title) != nil else { return .none }
    return source == .teams ? .teams : .user
  }
}

extension MeetingRecord {
  var needsAgentTitle: Bool { MeetingFiles.displayTitle(title) == nil }

  func validateAgentTitle(_ proposed: String?) throws {
    guard needsAgentTitle else {
      throw MeetingError(
        "This meeting already has a title. Agents can only name untitled meetings.")
    }
    guard MeetingFiles.displayTitle(proposed) != nil else {
      throw MeetingError("An agent must supply a nonempty meeting title.")
    }
  }
}

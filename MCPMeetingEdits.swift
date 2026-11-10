import Foundation

extension MCPServer {
  static var editToolNames: Set<String> {
    Set(editTools.compactMap { $0["name"]?.stringValue })
  }

  func editTool(_ name: String, _ arguments: [String: JSONValue]) throws -> ToolResult {
    let library = bridge.library
    func requiredString(_ key: String) throws -> String {
      guard let value = arguments[key]?.stringValue, !value.isEmpty else {
        throw MeetingError("Pass \(key).")
      }
      return value
    }
    let id = try MeetingAgentView.exactID(arguments, library: library)
    let revision = try MeetingAgentView.revision(arguments)
    let result: MeetingEditResult
    switch name {
    case "edit_transcript":
      guard case .array(let values) = arguments["changes"], !values.isEmpty, values.count <= 100
      else {
        throw MeetingError("Pass 1 to 100 changes with segment_id and replacement text.")
      }
      let changes = try values.map { value -> MeetingTextChange in
        guard let object = value.objectValue, Set(object.keys) == ["segment_id", "text"],
          let segment = object["segment_id"]?.stringValue, let text = object["text"]?.stringValue
        else { throw MeetingError("Each change needs only segment_id and text as strings.") }
        return MeetingTextChange(segmentID: segment, text: text)
      }
      result = try library.editTranscript(id, changes: changes, expectedRevision: revision)
    case "merge_speakers":
      guard case .array(let values) = arguments["merge"], !values.isEmpty,
        values.allSatisfy({ $0.stringValue != nil })
      else { throw MeetingError("Pass merge as a list of speaker labels to combine.") }
      if let value = arguments["name"], value.stringValue == nil {
        throw MeetingError("name must be a string.")
      }
      result = try library.mergeSpeakers(
        id, keep: requiredString("keep"), merge: values.compactMap(\.stringValue),
        name: arguments["name"]?.stringValue, expectedRevision: revision)
    case "update_meeting":
      var title: String??
      if let value = arguments["topic"] {
        guard let string = value.stringValue else { throw MeetingError("topic must be a string.") }
        title = .some(string)
      }
      var names: [String: String?]?
      if let value = arguments["speakers"] {
        guard let object = value.objectValue, object.values.allSatisfy({ $0.stringValue != nil })
        else {
          throw MeetingError("speakers must map speaker labels to names as strings.")
        }
        names = object.mapValues { $0.stringValue }
      }
      if let value = arguments["summary"], value.stringValue == nil {
        throw MeetingError("summary must be a string.")
      }
      let summary = arguments["summary"]?.stringValue
      guard title != nil || names?.isEmpty == false || summary != nil else {
        throw MeetingError("Pass a topic, summary or speaker names.")
      }
      result = try library.updateMeeting(
        id, title: title, names: names, summary: summary, expectedRevision: revision,
        titleSource: .agent)
    default:
      throw MeetingError("Unknown editing operation.")
    }
    var lines = [
      result.changed ? "Updated." : "No change needed.",
      "meeting_id: \(result.record.id)", "revision: \(result.record.revision)",
    ]
    if name == "update_meeting" {
      lines.append("Title: \(result.record.displayTitle)")
      if let summary = result.record.summary, arguments["summary"] != nil {
        lines.append("Summary: \(summary)")
      }
    }
    if name == "merge_speakers" || arguments["speakers"] != nil {
      lines.append(
        "Speakers: "
          + result.record.speakers.map { "\($0.label)=\($0.displayName)" }.joined(separator: "; "))
    }
    lines += MeetingAgentView.requiredActions(
      result.record, namesMeetings: agentsMayNameMeetings,
      summarizesMeetings: agentsMaySummarizeMeetings, correctsTranscripts: false)
    return .init(text: lines.joined(separator: "\n"))
  }

  static let editIdentity: [String: JSONValue] = [
    "meeting_id": ["type": "string", "description": "Exact meeting_id returned by a read."],
    "revision": [
      "type": "integer", "minimum": 0, "description": "Revision returned by that read.",
    ],
  ]

  static let editTools: [JSONValue] = [
    tool(
      "edit_transcript", title: "Correct transcript text",
      description:
        "Replace specified passages in one atomic change. Read each full passage, including continuation pages, and preserve meaning except for the requested correction.",
      properties: editIdentity.merging([
        "changes": [
          "type": "array", "minItems": 1, "maxItems": 100,
          "items": [
            "type": "object", "additionalProperties": false,
            "properties": ["segment_id": ["type": "string"], "text": ["type": "string"]],
            "required": ["segment_id", "text"],
          ],
        ]
      ]) { _, new in new }, required: ["meeting_id", "revision", "changes"], readOnly: false),
    tool(
      "merge_speakers", title: "Combine duplicate speakers",
      description:
        "Combine labels confirmed to represent the same person. Keep the chosen survivor; never merge people merely because their names match.",
      properties: editIdentity.merging([
        "keep": ["type": "string", "description": "Surviving speaker label."],
        "merge": ["type": "array", "minItems": 1, "items": ["type": "string"]],
        "name": [
          "type": "string",
          "description": "Optional resulting name; specify when existing names disagree.",
        ],
      ]) { _, new in new }, required: ["meeting_id", "revision", "keep", "merge"], readOnly: false),
    tool(
      "update_meeting", title: "Update meeting details",
      description:
        "Save a short summary, name an untitled meeting, or rename speakers.",
      properties: editIdentity.merging([
        "topic": [
          "type": "string", "description": "Title for an untitled meeting only.",
        ],
        "summary": [
          "type": "string", "maxLength": 1000,
          "description":
            "1–3 factual sentences from the full transcript; shorter for brief meetings.",
        ],
        "speakers": [
          "type": "object", "additionalProperties": ["type": "string"],
          "description": "Speaker label to name; empty name clears it.",
        ],
      ]) { _, new in new }, required: ["meeting_id", "revision"], readOnly: false),
  ]
}

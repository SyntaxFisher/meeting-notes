import Foundation

/// Turns the helper's segments into the transcript text and the meeting record's speakers and
/// segments. The text starts with a short header that explains every speaker label, followed by
/// one `[hh:mm:ss] Label: text` line per turn.
enum TranscriptDocument {
  static let fallbackLocalName = "Me"
  /// The helper ends a segment at every diarizer turn, so naming can tell apart people the
  /// diarizer heard as one voice. Consecutive segments with the same label, a pause shorter than
  /// `joinedPause` and together shorter than `longestJoinedTurn` become one turn again.
  static let joinedPause = 1.0
  static let longestJoinedTurn = 60.0

  /// The name for everything the microphone recorded: the configured name, else the Teams
  /// display name, else the macOS full name.
  static func localSpeakerName(
    configured: String?, teamsName: String?, fullUserName: String = NSFullUserName()
  ) -> String {
    for candidate in [configured, teamsName, fullUserName] {
      if let name = cleanedName(candidate) { return name }
    }
    return fallbackLocalName
  }

  /// A usable speaker label: trimmed, non-empty and without a colon, which ends the label in
  /// transcript lines.
  static func cleanedName(_ name: String?) -> String? {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
      !name.contains(":")
    else { return nil }
    return name
  }

  /// The participant all remote Teams speech belongs to when Teams listed only one besides the
  /// local participant.
  private static func soleRemoteParticipant(
    _ result: TranscriptSegments, roster: ParticipantRoster?
  )
    -> String?
  {
    let remote = roster?.remoteParticipants ?? []
    return result.mode == .separateTracks && remote.count == 1 ? remote[0].name : nil
  }

  /// Each segment's Teams name with its evidence, or nil when Teams speaker readings do not
  /// apply to this result.
  static func naming(
    _ result: TranscriptSegments, localName: String, roster: ParticipantRoster?,
    speaking: SpeakingTimeline?
  ) -> [SpeakerFusion.Decision]? {
    guard result.mode == .separateTracks, soleRemoteParticipant(result, roster: roster) == nil,
      let speaking
    else { return nil }
    let resolved = roster?.resolvedTileNames
    var timeline = speaking
    if let aliases = resolved?.aliases, !aliases.isEmpty {
      for index in timeline.intervals.indices {
        let name = timeline.intervals[index].name
        timeline.intervals[index].name = aliases[name] ?? name
      }
    }
    return SpeakerNaming.decisions(
      for: result.segments, timeline: timeline,
      excluded: [localName, roster?.localParticipant?.name].compactMap { $0 },
      embeddings: result.voiceEmbeddings ?? [],
      participants: roster?.sawFullRoster == true
        ? resolved?.roster.remoteParticipants.map(\.name) : nil)
  }

  /// Fills the record's speakers, segments, participants and duration from the helper's result
  /// and returns the transcript text. `speaking` is when Teams showed each participant speaking,
  /// on the result's timeline; it names remote Teams voices.
  static func compose(
    _ result: TranscriptSegments, into record: inout MeetingRecord, localName: String,
    roster: ParticipantRoster?, speaking: SpeakingTimeline? = nil, timeZone: TimeZone = .current
  ) -> String {
    compose(
      result, into: &record, localName: localName, roster: roster,
      naming: naming(result, localName: localName, roster: roster, speaking: speaking),
      timeZone: timeZone)
  }

  /// `compose` with the segments' naming decisions already made by `naming`.
  static func compose(
    _ result: TranscriptSegments, into record: inout MeetingRecord, localName: String,
    roster: ParticipantRoster?, naming decisions: [SpeakerFusion.Decision]?,
    timeZone: TimeZone = .current
  ) -> String {
    let soleRemote = soleRemoteParticipant(result, roster: roster)
    let teamsNames = decisions?.map { $0.name.flatMap(cleanedName) }
    var anonymousLabels: [String: String] = [:]
    var speakers: [MeetingSpeaker] = []
    var anonymous = 0
    var segmentLabels: [String] = []
    for (index, segment) in result.segments.enumerated() {
      let label: String
      let identity: MeetingSpeaker.Identity
      var participant: String?
      switch segment.source {
      case .microphone:
        label = localName
        identity = .localUser
        participant = roster?.localParticipant?.name
      case .teams where soleRemote != nil:
        label = soleRemote!
        identity = .soleRemoteParticipant
        participant = soleRemote
      case .teams where teamsNames?[index].map({ $0 != localName }) == true:
        label = teamsNames![index]!
        identity = .teamsSpeaker
        participant = label
      case .teams, .deviceAudio, .app, .mix:
        let key = "\(segment.source.rawValue)/\(segment.speaker)"
        if anonymousLabels[key] == nil {
          anonymous += 1
          anonymousLabels[key] = "Speaker \(anonymous)"
        }
        label = anonymousLabels[key]!
        identity = .unidentified
      }
      segmentLabels.append(label)
      if !speakers.contains(where: { $0.label == label }) {
        speakers.append(
          MeetingSpeaker(
            label: label, isLocalUser: identity == .localUser, identity: identity,
            source: segment.source, participant: participant))
      }
    }
    var turns: [(segment: TranscriptSegments.Segment, label: String)] = []
    for (segment, label) in zip(result.segments, segmentLabels) {
      if var last = turns.last, last.label == label, last.segment.source == segment.source,
        segment.start - last.segment.end < joinedPause,
        segment.end - last.segment.start < longestJoinedTurn
      {
        last.segment.end = max(last.segment.end, segment.end)
        last.segment.text += " " + segment.text
        turns[turns.count - 1] = last
      } else {
        turns.append((segment, label))
      }
    }
    for (segment, label) in turns {
      let speaker = speakers.firstIndex { $0.label == label }!
      speakers[speaker].turns += 1
      speakers[speaker].seconds += max(0, segment.end - segment.start)
    }
    for index in speakers.indices {
      speakers[index].seconds = (speakers[index].seconds * 10).rounded() / 10
    }
    let segments = turns.map { segment, label in
      MeetingSegment(
        start: MeetingRecord.seconds(segment.start), end: MeetingRecord.seconds(segment.end),
        speaker: label, text: segment.text)
    }
    let duration = MeetingRecord.seconds(result.duration)
    record.durationSeconds = duration
    record.endedAt = record.startedAt.addingTimeInterval(duration)
    record.transcription = MeetingTranscription(
      mode: result.mode, engine: result.engine, echo: result.echo)
    record.speakers = speakers.map { speaker in
      var speaker = speaker
      speaker.name = record.speakers.first { $0.label == speaker.label }?.name
      return speaker
    }
    record.participants = roster?.resolvedTileNames.roster
    record.segments = segments
    var lines = header(record, timeZone: timeZone)
    lines.append("")
    lines.append(
      segments.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(
        separator: "\n\n"))
    return lines.joined(separator: "\n") + "\n"
  }

  /// The transcript as copied for use outside the app: the header with the names currently
  /// assigned to the speakers, the saved summary and every turn.
  static func shareableText(_ record: MeetingRecord, timeZone: TimeZone = .current) -> String {
    var lines = header(record, timeZone: timeZone, assignedNames: true)
    if !record.segments.isEmpty {
      lines.append("")
      lines.append(
        record.segments.map {
          "[\(timestamp($0.start))] \(record.displayName(for: $0.speaker)): \($0.text)"
        }.joined(separator: "\n\n"))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  enum SpeakerLegend {
    /// The labels the transcript file uses.
    case labels
    /// The names assigned after transcription.
    case assignedNames
    /// `label=name`, for readers that see labels in the passages and address speakers by them.
    case labelsWithAssignedNames
  }

  private static func header(
    _ metadata: MeetingRecord, timeZone: TimeZone, assignedNames: Bool = false
  ) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let end = DateFormatter()
    end.locale = formatter.locale
    end.timeZone = timeZone
    end.dateFormat = "HH:mm"
    var lines = [
      metadata.title ?? "Meeting",
      "Recorded \(formatter.string(from: metadata.startedAt))–\(end.string(from: metadata.endedAt ?? metadata.startedAt)) (\(duration(metadata.durationSeconds ?? 0)))",
    ]
    if assignedNames, let summary = metadata.summary, !summary.isEmpty {
      lines += ["", "Summary:", summary]
    }
    lines += ["", "Speakers:"]
    lines += speakerLines(metadata, naming: assignedNames ? .assignedNames : .labels)
    let participants = participantLines(metadata)
    if !participants.isEmpty { lines += [""] + participants }
    return lines
  }

  /// One line per speaker saying where the name comes from and how far it can be trusted.
  static func speakerLines(_ metadata: MeetingRecord, naming: SpeakerLegend) -> [String] {
    let assigned = naming != .labels
    func name(_ speaker: MeetingSpeaker) -> String {
      switch naming {
      case .labels: speaker.label
      case .assignedNames: speaker.displayName
      case .labelsWithAssignedNames:
        speaker.name.map { "\(speaker.label)=\($0)" } ?? speaker.label
      }
    }
    func anonymousSource(_ speaker: MeetingSpeaker?) -> String {
      switch speaker?.source {
      case .mix, nil:
        metadata.source == .microphone
          ? "voices this Mac's microphone recorded" : "voices in the mixed recording"
      case .deviceAudio: "remote voices in the device audio (everything this Mac played)"
      case .app: "remote voices in the \(metadata.source?.systemAudio?.label ?? "app audio")"
      case .teams, .microphone: "remote voices in the Teams audio"
      }
    }
    var lines: [String] = []
    for speaker in metadata.speakers where speaker.identity != .unidentified {
      switch speaker.identity {
      case .localUser:
        let teams = speaker.participant.map { "; \"\($0)\" in Teams" } ?? ""
        let you = naming == .labelsWithAssignedNames ? " (you)" : ""
        lines.append(
          "- \(name(speaker))\(you): everything this Mac's microphone recorded\(teams)")
      case .soleRemoteParticipant:
        lines.append(
          "- \(name(speaker)): the Teams audio; Teams listed no other remote participant")
      case .teamsSpeaker:
        lines.append(
          "- \(name(speaker)): a voice in the Teams audio while Teams showed them speaking")
      case .unidentified: break
      }
    }
    let unidentified = metadata.speakers.filter { $0.identity == .unidentified }
    for speaker in unidentified where assigned && speaker.name != nil {
      lines.append(
        "- \(name(speaker)): one of the \(anonymousSource(speaker)), told apart by sound; named after transcription"
      )
    }
    let anonymous = unidentified.filter { !(assigned && $0.name != nil) }
    if !anonymous.isEmpty {
      lines.append(
        "- \(anonymous.map(\.label).joined(separator: ", ")): \(anonymousSource(anonymous.first)), told apart by sound; not matched to names"
      )
    }
    return lines
  }

  /// The participants Teams showed, under a heading saying whether the list is complete.
  static func participantLines(_ metadata: MeetingRecord) -> [String] {
    guard let roster = metadata.participants, !roster.participants.isEmpty else { return [] }
    var lines = [
      roster.sawFullRoster
        ? "Participants in Teams:" : "Participants with a visible Teams video tile:"
    ]
    for participant in roster.participants {
      var details = [participant.role, participant.tag].compactMap { $0 }
      if participant.isLocal { details.append("this Mac") }
      let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
      lines.append(
        "- \(participant.name)\(suffix), seen \(timestamp(participant.firstSeen))–\(timestamp(participant.lastSeen))"
      )
    }
    return lines
  }

  static func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
  }

  private static func duration(_ seconds: Double) -> String {
    let value = Int(seconds.rounded())
    if value >= 3600 { return "\(value / 3600) h \(value / 60 % 60) min" }
    if value >= 60 { return "\(value / 60) min \(value % 60) s" }
    return "\(value) s"
  }
}

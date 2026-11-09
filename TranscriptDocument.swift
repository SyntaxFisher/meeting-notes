import Foundation

/// Turns the helper's segments into the transcript text and the meeting record's speakers and
/// segments. The text starts with a short header that explains every speaker label, followed by
/// one `[hh:mm:ss] Label: text` line per turn.
enum TranscriptDocument {
  static let fallbackLocalName = "Me"

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

  /// Fills the record's speakers, segments, participants and duration from the helper's result
  /// and returns the transcript text. `speaking` is when Teams showed each participant speaking,
  /// on the result's timeline; it names remote Teams voices.
  static func compose(
    _ result: TranscriptSegments, into record: inout MeetingRecord, localName: String,
    roster: ParticipantRoster?, speaking: SpeakingTimeline? = nil, timeZone: TimeZone = .current
  ) -> String {
    let remote = roster?.remoteParticipants ?? []
    let soleRemote = result.mode == .separateTracks && remote.count == 1 ? remote[0].name : nil
    let excluded = [localName, roster?.localParticipant?.name].compactMap { $0 }
    let teamsNames =
      result.mode == .separateTracks && soleRemote == nil
      ? speaking.map {
        SpeakerNaming.names(for: result.segments, timeline: $0, excluded: excluded)
          .map { $0.flatMap(cleanedName) }
      } : nil
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
      let speaker = speakers.firstIndex { $0.label == label }!
      speakers[speaker].turns += 1
      speakers[speaker].seconds += max(0, segment.end - segment.start)
    }
    for index in speakers.indices {
      speakers[index].seconds = (speakers[index].seconds * 10).rounded() / 10
    }
    let segments = zip(result.segments, segmentLabels).map { segment, label in
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
    record.participants = roster
    record.segments = segments
    var lines = header(record, timeZone: timeZone)
    lines.append("")
    lines.append(
      segments.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(
        separator: "\n\n"))
    return lines.joined(separator: "\n") + "\n"
  }

  private static func header(_ metadata: MeetingRecord, timeZone: TimeZone) -> [String] {
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
      "",
      "Speakers:",
    ]
    for speaker in metadata.speakers where speaker.identity != .unidentified {
      switch speaker.identity {
      case .localUser:
        let teams = speaker.participant.map { "; \"\($0)\" in Teams" } ?? ""
        lines.append("- \(speaker.label): everything this Mac's microphone recorded\(teams)")
      case .soleRemoteParticipant:
        lines.append(
          "- \(speaker.label): the Teams audio; Teams listed no other remote participant")
      case .teamsSpeaker:
        lines.append(
          "- \(speaker.label): a voice in the Teams audio while Teams showed them speaking")
      case .unidentified: break
      }
    }
    let unidentified = metadata.speakers.filter { $0.identity == .unidentified }
    let anonymous = unidentified.map(\.label)
    if !anonymous.isEmpty {
      let source =
        switch unidentified.first?.source {
        case .mix, nil:
          metadata.source == .microphone
            ? "voices this Mac's microphone recorded" : "voices in the mixed recording"
        case .deviceAudio: "remote voices in the device audio (everything this Mac played)"
        case .app: "remote voices in the \(metadata.source?.systemAudio?.label ?? "app audio")"
        case .teams, .microphone: "remote voices in the Teams audio"
        }
      lines.append(
        "- \(anonymous.joined(separator: ", ")): \(source), told apart by sound; not matched to names"
      )
    }
    if let roster = metadata.participants, !roster.participants.isEmpty {
      lines.append("")
      lines.append(
        roster.sawFullRoster
          ? "Participants in Teams:" : "Participants with a visible Teams video tile:")
      for participant in roster.participants {
        var details = [participant.role, participant.tag].compactMap { $0 }
        if participant.isLocal { details.append("this Mac") }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        lines.append(
          "- \(participant.name)\(suffix), seen \(timestamp(participant.firstSeen))–\(timestamp(participant.lastSeen))"
        )
      }
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

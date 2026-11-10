import Foundation

enum SpeakerFusionSmoke {
  private static func segment(_ start: Double, _ end: Double, _ voice: String)
    -> TranscriptSegments.Segment
  {
    .init(start: start, end: end, source: .teams, speaker: voice, text: "Speech")
  }

  private static func shown(_ name: String, _ start: Double, _ end: Double)
    -> SpeakingTimeline.Interval
  {
    .init(
      name: name, start: start + SpeakerNaming.onsetDelay,
      end: end + SpeakerNaming.releaseDelay)
  }

  private static func embedding(_ segment: TranscriptSegments.Segment, _ vector: [Float])
    -> TranscriptSegments.VoiceEmbedding
  {
    .init(speaker: segment.speaker, start: segment.start, end: segment.end, values: vector)
  }

  static func run() throws {
    let sparse = [segment(0, 90, "S1"), segment(100, 104, "S1")]
    precondition(
      SpeakerNaming.names(
        for: sparse, timeline: .init(intervals: [shown("Anna", 100, 103)])) == ["Anna", "Anna"],
      "A later clear anchor names earlier speech despite long gaps in Teams indications")

    let turns = [
      segment(0, 8, "S1"), segment(12, 20, "S2"),
      segment(24, 32, "S3"), segment(36, 44, "S4"),
    ]
    let timeline = SpeakingTimeline(intervals: [shown("Anna", 0, 8), shown("Sam", 12, 20)])
    let vectors: [[Float]] = [[1, 0, 0], [0, 1, 0], [0.98, 0.02, 0], [0.02, 0.98, 0]]
    let embeddings = zip(turns, vectors).map { embedding($0.0, $0.1) }
    let named = SpeakerNaming.names(for: turns, timeline: timeline, embeddings: embeddings)
    precondition(named == ["Anna", "Sam", "Anna", "Sam"], "Split voice clusters share names")

    let merged = turns.map { turn in
      var turn = turn
      turn.speaker = "S1"
      return turn
    }
    precondition(
      SpeakerNaming.names(
        for: merged, timeline: timeline,
        embeddings: zip(merged, vectors).map { embedding($0.0, $0.1) }) == named,
      "A cluster containing two people is resolved acoustically per turn")

    var uncertain = embeddings
    uncertain[2].values = [0.72, 0.69, 0]
    uncertain[3].values = [0, 0, 1]
    precondition(
      SpeakerNaming.names(for: turns, timeline: timeline, embeddings: uncertain)
        == ["Anna", "Sam", nil, nil],
      "Similar candidates and a genuinely new voice stay unidentified")

    let stale = SpeakingTimeline(
      intervals: timeline.intervals + [shown("Sam", 24, 27.3)])
    precondition(
      SpeakerNaming.names(for: turns, timeline: stale, embeddings: embeddings)[2] == "Anna",
      "A weak stale Teams indicator cannot override a clear acoustic match")

    let contradictory = SpeakingTimeline(
      intervals: timeline.intervals + [shown("Sam", 24, 32)])
    let conflict = SpeakerNaming.names(
      for: turns, timeline: contradictory, embeddings: embeddings)
    precondition(conflict[2] != "Anna", "Strong conflicting evidence cannot silently be discarded")

    precondition(
      SpeakerNaming.names(for: turns, timeline: .init(), embeddings: embeddings)
        == [nil, nil, nil, nil], "Voice separation cannot invent names without anchors")
    let overlap = SpeakingTimeline(
      intervals: [shown("Anna", 0, 8), shown("Sam", 0, 8)])
    precondition(
      SpeakerNaming.names(for: turns, timeline: overlap, embeddings: embeddings)
        == [nil, nil, nil, nil], "Simultaneous Teams indicators do not train voice references")
    let duplicates = SpeakingTimeline(
      intervals: Array(repeating: shown("Anna", 0, 8), count: 12) + [shown("Sam", 0, 8)])
    precondition(
      SpeakerNaming.names(for: turns, timeline: duplicates, embeddings: embeddings)
        == [nil, nil, nil, nil], "Duplicate readings cannot outweigh contradictory evidence")

    var invalid = embeddings
    invalid[2].values = [0, 0, 0]
    invalid[3].values = [.nan, .infinity, 0]
    precondition(
      SpeakerNaming.names(for: turns, timeline: timeline, embeddings: invalid)
        == ["Anna", "Sam", nil, nil])
    invalid[2].values = [1, 0]
    invalid[3].values = []
    precondition(
      SpeakerNaming.names(for: turns, timeline: timeline, embeddings: invalid)
        == ["Anna", "Sam", nil, nil], "Incompatible vectors are ignored")

    let unidentified = [segment(0, 8, "unidentified"), segment(12, 20, "unidentified")]
    precondition(
      SpeakerNaming.names(for: unidentified, timeline: .init(intervals: [shown("Anna", 0, 8)]))
        == ["Anna", nil], "VAD fallback is not evidence that every voice is the same person")
    var otherSource = turns
    otherSource[2].source = .deviceAudio
    otherSource[3].source = .microphone
    precondition(
      SpeakerNaming.names(for: otherSource, timeline: timeline, embeddings: embeddings)
        == ["Anna", "Sam", nil, nil], "Teams identities never leak to other audio sources")
    precondition(
      SpeakerNaming.names(
        for: turns, timeline: timeline, excluded: ["Anna"], embeddings: embeddings)[2] == nil,
      "The local identity is excluded from reference voices")

    let result = TranscriptSegments(
      mode: .separateTracks, duration: 44, segments: turns, voiceEmbeddings: embeddings,
      engine: "fixture")
    let decoded = try JSONDecoder().decode(
      TranscriptSegments.self, from: JSONEncoder().encode(result))
    precondition(decoded == result, "Helper IPC preserves embeddings and timing")
    print("Speaker fusion: sparse, split, merged, conflicting, overlapping and unknown voices: OK")
  }

  static func replay(_ arguments: [String]) throws -> Bool {
    guard arguments.count == 6, arguments[1] == "--speaker-fusion-replay" else { return false }
    let result = try JSONDecoder().decode(
      TranscriptSegments.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let capture = URL(fileURLWithPath: arguments[3])
    let roster = try JSONDecoder().decode(
      ParticipantRoster.self,
      from: Data(contentsOf: capture.appendingPathComponent("participants.json")))
    var record = MeetingRecord(id: "fixture", startedAt: Date(), status: .complete)
    let text = TranscriptDocument.compose(
      result, into: &record, localName: roster.localParticipant?.name ?? "Me", roster: roster,
      speaking: SpeakingTimeline.load(fromCapture: capture))
    try Data(text.utf8).write(
      to: URL(fileURLWithPath: arguments[4]), options: .withoutOverwriting)
    try JSONEncoder().encode(record).write(
      to: URL(fileURLWithPath: arguments[5]), options: .withoutOverwriting)
    print(record.speakers.map(\.label).joined(separator: ", "))
    return true
  }
}

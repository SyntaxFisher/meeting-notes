import Foundation

/// Names remote voices in the Teams audio after the participants Teams showed speaking.
///
/// Teams marks the active speaker about a second after speech starts and keeps the mark about
/// two seconds after it ends, and the app reads the mark every 0.8 s, so each reading interval
/// is moved earlier before it is compared with the transcript. A remote turn takes the name that
/// covers much of it and clearly outweighs any other. When Teams framed several participants
/// and none outweighs the others, a name whose indicator switched on for the turn wins over
/// indicators still on, or back on after a moment, from earlier speech. A turn without such
/// evidence takes the name that dominates its voice, the diarizer's cluster, across the
/// meeting.
///
/// Voice evidence then names turns these readings leave anonymous when Teams and the voice
/// agree without contradiction, and replaces a reading only when the voice clearly contradicts
/// it (`SpeakerFusion`). Anything else keeps its label, because a wrong name is worse than none.
enum SpeakerNaming {
  static let onsetDelay = 1.1
  static let releaseDelay = 1.6
  /// The shortest a single reading counts, in seconds.
  static let minimumInterval = 0.5
  /// The share of a turn a name must cover, and how many times the runner-up it must be.
  static let turnCoverage = 0.4
  static let dominance = 2.0
  /// The share of a voice's named time its leading name must hold, and the share of the voice's
  /// speech that must be named at all.
  static let voiceShare = 0.7
  static let voiceCoverage = 0.25
  /// An indicator back this soon after the same name's last one resumed it: Teams keeps a
  /// frame about two seconds after speech, and readings briefly lose sight of the meeting.
  static let resumeGap = 5.0

  /// The name for each segment, or nil. `timeline` is on the segments' timeline; names in
  /// `excluded` (the local participant, whose voice is not in the Teams audio) are ignored.
  /// `participants` are the remote participants when Teams listed all of them.
  static func names(
    for segments: [TranscriptSegments.Segment], timeline: SpeakingTimeline,
    excluded: [String] = [], embeddings: [TranscriptSegments.VoiceEmbedding] = [],
    participants: [String]? = nil
  ) -> [String?] {
    decisions(
      for: segments, timeline: timeline, excluded: excluded, embeddings: embeddings,
      participants: participants
    ).map(\.name)
  }

  /// Each segment's name with the evidence that chose it.
  static func decisions(
    for segments: [TranscriptSegments.Segment], timeline: SpeakingTimeline,
    excluded: [String] = [], embeddings: [TranscriptSegments.VoiceEmbedding] = [],
    participants: [String]? = nil
  ) -> [SpeakerFusion.Decision] {
    let readings = readingNames(for: segments, timeline: timeline, excluded: excluded)
    return SpeakerFusion(
      segments: segments, timeline: timeline, excluded: excluded, readings: readings,
      embeddings: embeddings, participants: participants
    ).decisions()
  }

  /// Names from Teams readings alone.
  static func readingNames(
    for segments: [TranscriptSegments.Segment], timeline: SpeakingTimeline,
    excluded: [String] = []
  ) -> [String?] {
    let excludedKeys = Set(excluded.map(key))
    let raw = timeline.intervals.filter { !excludedKeys.contains(key($0.name)) }
    let intervals = raw.map { interval -> SpeakingTimeline.Interval in
      let start = interval.start - onsetDelay
      return .init(
        name: interval.name, start: start,
        end: max(start + minimumInterval, interval.end - releaseDelay))
    }
    // Indicators that switched on rather than resumed shortly after the same name's last one.
    let switchedOn = raw.indices.map { index in
      !raw.indices.contains { other in
        other != index && raw[other].name == raw[index].name && raw[other].start < raw[index].start
          && raw[index].start - raw[other].end <= resumeGap
      }
    }
    let remote = segments.map { $0.source == .teams }
    guard !intervals.isEmpty, remote.contains(true) else { return segments.map { _ in nil } }
    let coverage = segments.enumerated().map { index, segment -> [String: Double] in
      guard remote[index] else { return [:] }
      var seconds: [String: Double] = [:]
      for interval in intervals {
        let overlap = min(segment.end, interval.end) - max(segment.start, interval.start)
        if overlap > 0 { seconds[interval.name, default: 0] += overlap }
      }
      return seconds
    }
    var voiceSeconds: [String: Double] = [:]
    var voiceCoverage: [String: [String: Double]] = [:]
    for (index, segment) in segments.enumerated() where remote[index] {
      voiceSeconds[segment.speaker, default: 0] += duration(segment)
      voiceCoverage[segment.speaker, default: [:]].merge(coverage[index], uniquingKeysWith: +)
    }
    var voiceNames: [String: String] = [:]
    for (voice, seconds) in voiceCoverage {
      let named = seconds.values.reduce(0, +)
      guard let (name, leading) = seconds.max(by: { $0.value < $1.value }),
        leading >= voiceShare * named, named >= self.voiceCoverage * (voiceSeconds[voice] ?? 0)
      else { continue }
      voiceNames[voice] = name
    }
    return segments.enumerated().map { index, segment in
      guard remote[index] else { return nil }
      let ranked = coverage[index].sorted { $0.value > $1.value }
      let covering = ranked.filter { $0.value >= turnCoverage * duration(segment) }
      if let first = covering.first, ranked.count == 1 || first.value >= dominance * ranked[1].value
      {
        return first.key
      }
      let fresh = covering.filter { name, _ in
        intervals.indices.contains { interval in
          intervals[interval].name == name && switchedOn[interval]
            && intervals[interval].start >= segment.start - SpeakerFusion.onsetLead
            && intervals[interval].start < segment.end
        }
      }
      if fresh.count == 1, covering.count > 1 { return fresh[0].key }
      return voiceNames[segment.speaker]
    }
  }

  static func duration(_ segment: TranscriptSegments.Segment) -> Double {
    max(0.3, segment.end - segment.start)
  }

  static func key(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

extension SpeakingTimeline {
  /// The timeline a recording collected in `capture/speaking.json`, moved onto the transcript's
  /// timeline, which starts with the earlier capture track.
  static func load(fromCapture capture: URL) -> SpeakingTimeline? {
    guard
      let data = try? Data(contentsOf: capture.appendingPathComponent("speaking.json")),
      let timeline = try? JSONDecoder().decode(SpeakingTimeline.self, from: data),
      let manifestData = try? Data(contentsOf: capture.appendingPathComponent("capture.json")),
      let manifest = try? JSONDecoder().decode(CaptureManifest.self, from: manifestData),
      let system = manifest.systemStart, let microphone = manifest.microphoneStart
    else { return nil }
    let origin = min(system, microphone)
    return SpeakingTimeline(
      intervals: timeline.intervals.map {
        .init(name: $0.name, start: $0.start - origin, end: $0.end - origin)
      })
  }
}

import Foundation

/// Names remote voices in the Teams audio after the participants Teams showed speaking.
///
/// Reliable Teams readings anchor names to voices across the whole recording, including
/// earlier speech. Missing indications do not count against an established identity.
/// Acoustic references come only from direct Teams evidence; inferred names never train
/// further matches. Contradictory clusters are resolved per turn instead of forcing one name.
enum SpeakerNaming {
  static let onsetDelay = 1.1
  static let releaseDelay = 1.6
  /// The shortest a single reading counts, in seconds.
  static let minimumInterval = 0.5
  /// The share of a turn a name must cover, and how many times the runner-up it must be.
  static let turnCoverage = 0.4
  static let dominance = 2.0
  static let anchorCoverage = 0.45
  static let minimumAnchorSeconds = 1.5
  static let voiceShare = 0.8

  struct Evidence {
    var seconds: [String: Double]
    var duration: Double

    var ranked: [(key: String, value: Double)] {
      seconds.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }

    var direct: String? {
      guard let first = ranked.first, first.value >= turnCoverage * duration,
        ranked.count == 1 || first.value >= dominance * ranked[1].value
      else { return nil }
      return first.key
    }

    var anchor: String? {
      guard let name = direct, seconds[name, default: 0] >= minimumAnchorSeconds,
        seconds[name, default: 0] >= anchorCoverage * duration
      else { return nil }
      return name
    }
  }

  /// The name for each segment, or nil. `timeline` is on the segments' timeline; names in
  /// `excluded` (the local participant, whose voice is not in the Teams audio) are ignored.
  static func names(
    for segments: [TranscriptSegments.Segment], timeline: SpeakingTimeline,
    excluded: [String] = [], embeddings: [TranscriptSegments.VoiceEmbedding] = []
  ) -> [String?] {
    let excludedKeys = Set(excluded.map(key))
    let intervals = exclusiveIntervals(timeline, excluding: excludedKeys)
    let evidence = segments.map { segment in
      Evidence(
        seconds: segment.source == .teams ? coverage(segment, intervals: intervals) : [:],
        duration: duration(segment))
    }
    let voiceNames = clusterNames(segments, evidence: evidence)
    let matcher = SpeakerVoiceMatcher(
      segments: segments, embeddings: embeddings, anchors: evidence.map(\.anchor))
    return segments.enumerated().map { index, segment in
      guard segment.source == .teams else { return nil }
      let direct = evidence[index].direct
      let cluster = voiceNames[segment.speaker]
      if let acoustic = matcher.name(for: index) {
        if let anchor = evidence[index].anchor, anchor != acoustic, cluster != acoustic {
          return nil
        }
        return acoustic
      }
      return evidence[index].anchor ?? cluster ?? direct
    }
  }

  private static func clusterNames(
    _ segments: [TranscriptSegments.Segment], evidence: [Evidence]
  ) -> [String: String] {
    var votes: [String: [String: Double]] = [:]
    var anchors: [String: Set<String>] = [:]
    for (index, segment) in segments.enumerated()
    where segment.source == .teams && segment.speaker != "unidentified" {
      guard let name = evidence[index].direct else { continue }
      votes[segment.speaker, default: [:]][name, default: 0] +=
        evidence[index].seconds[name, default: 0]
      if let anchor = evidence[index].anchor {
        anchors[segment.speaker, default: []].insert(anchor)
      }
    }
    return votes.compactMapValues { seconds -> String? in
      guard let leading = seconds.max(by: { $0.value < $1.value }),
        leading.value >= minimumAnchorSeconds,
        leading.value >= voiceShare * seconds.values.reduce(0, +)
      else { return nil }
      return leading.key
    }.filter { voice, _ in anchors[voice, default: []].count <= 1 }
  }

  /// Overlapping indicators are ambiguous, and duplicate readings cannot multiply evidence.
  private static func exclusiveIntervals(
    _ timeline: SpeakingTimeline, excluding: Set<String>
  ) -> [SpeakingTimeline.Interval] {
    var displayNames: [String: String] = [:]
    var changes: [Double: [String: Int]] = [:]
    for interval in timeline.intervals {
      let name = interval.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let canonical = key(name)
      guard !name.isEmpty, !excluding.contains(canonical), interval.start.isFinite,
        interval.end.isFinite, interval.end >= interval.start
      else { continue }
      displayNames[canonical] = displayNames[canonical] ?? name
      let start = interval.start - onsetDelay
      let end = max(start + minimumInterval, interval.end - releaseDelay)
      changes[start, default: [:]][canonical, default: 0] += 1
      changes[end, default: [:]][canonical, default: 0] -= 1
    }
    var active: [String: Int] = [:]
    var previous: Double?
    var result: [SpeakingTimeline.Interval] = []
    for time in changes.keys.sorted() {
      if let previous, time > previous, active.count == 1, let name = active.keys.first {
        result.append(.init(name: displayNames[name]!, start: previous, end: time))
      }
      for (name, delta) in changes[time]! {
        active[name, default: 0] += delta
        if active[name] == 0 { active[name] = nil }
      }
      previous = time
    }
    return result
  }

  private static func coverage(
    _ segment: TranscriptSegments.Segment, intervals: [SpeakingTimeline.Interval]
  ) -> [String: Double] {
    var seconds: [String: Double] = [:]
    for interval in intervals {
      let overlap = min(segment.end, interval.end) - max(segment.start, interval.start)
      if overlap > 0 { seconds[interval.name, default: 0] += overlap }
    }
    return seconds
  }

  private static func duration(_ segment: TranscriptSegments.Segment) -> Double {
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

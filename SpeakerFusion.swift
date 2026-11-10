import Foundation

/// Checks Teams readings against FluidAudio's voice embeddings of the same recording: names
/// turns the readings left anonymous, and corrects a reading the voice clearly contradicts.
///
/// A voice reference comes only from anchor turns: turns a single participant's indicator
/// covers clearly and switched on during. An indicator that merely continues from the previous
/// turn is not an anchor, because it can outlast its speaker. Each anchor must sound like the
/// participant's other anchors; one that does not is quarantined together with its voice.
///
/// An anonymous turn takes a name in two ways. Within a diarizer voice whose anchors and
/// readings all name one participant, every embedding of the turn must match that
/// participant's reference and clearly no other. A voice without any Teams evidence takes a
/// name only when Teams listed every participant, each speaking participant has a reference,
/// and the whole voice matches one of them by a wide margin. A turn without an embedding of its
/// own, or that FluidAudio also heard another voice speak through, keeps its anonymous label
/// either way.
///
/// A reading changes only for a long turn without another voice whose every embedding matches
/// another participant by a wide margin and sounds unlike the reading's participant, both from
/// references of at least two anchors that leave the turn out. Weak or missing voice evidence
/// never removes a reading.
struct SpeakerFusion {
  enum Reason: String, Codable {
    case teamsReading = "teams-reading"
    case voiceOfNamedCluster = "voice-of-named-cluster"
    case voiceMatch = "voice-match"
    case voiceCorrection = "voice-correction"
    case unidentified
  }

  /// A segment's name, why it was chosen, whether the turn is an anchor, the voice similarity
  /// that decided it, and for a correction the name Teams readings had chosen. When voice
  /// evidence named or corrected nothing, `rejection` is the first safeguard that stopped it;
  /// `candidate` is the reference the turn's voice resembles most, with its similarity and that
  /// of the next reference, weighted by the speech each embedding covers.
  struct Decision: Codable, Equatable {
    var name: String?
    var reason: Reason
    var anchor: Bool = false
    var similarity: Double? = nil
    var reading: String? = nil
    var rejection: String? = nil
    var candidate: String? = nil
    var candidateSimilarity: Double? = nil
    var runnerUpSimilarity: Double? = nil
  }

  static let anchorSeconds = 1.5
  static let anchorShare = 0.5
  /// Other names may cover at most this share of an anchor's own coverage.
  static let anchorPurity = 0.2
  /// How far an indicator may switch on before the turn, and must before its last second.
  static let onsetLead = 1.0
  static let onsetTail = 1.0
  /// Embeddings of shorter speech vary too much to compare voices.
  static let chunkSeconds = 3.0
  /// An anchor's similarity to the participant's other anchors.
  static let anchorConsistency = 0.65
  /// References this similar cannot tell their participants apart.
  static let distinctReferences = 0.7
  /// Similarity to the reference and lead over every other reference, within a named voice
  /// and for a voice without Teams evidence.
  static let clusterMatch = 0.7
  static let clusterMargin = 0.12
  static let voiceMatch = 0.75
  static let voiceMargin = 0.15
  static let voiceAverage = 0.8
  /// The share of a named voice's speech its anchors must cover, and the share of all its
  /// indicator time the anchored participant must hold.
  static let clusterSupport = 0.1
  static let clusterShare = 0.8
  /// A reference from a single anchor cannot be checked against another one, so it names only
  /// turns of its own voice, and only when its indicator switched on this close to the turn's
  /// start, as Teams does for the person who speaks rather than for a sound in the middle.
  static let alignedOnset = 1.0
  /// Indicator time for other participants a voice without Teams evidence may have.
  static let strayIndication = 0.5
  /// A turn this much spanned by another voice's embedding may hold that voice's speech.
  static let foreignVoice = 0.25
  /// A name from readings changes only for a turn whose own embeddings cover this much distinct
  /// speech in it, when both participants have references from this many other anchors, every
  /// embedding leads by `correctionMargin`, and the turn sounds at most `contradiction` like the
  /// name. Overlapping windows over the same speech count once.
  static let correctionSpeech = 6.0
  static let correctionReferences = 2
  static let correctionMargin = 0.25
  static let contradiction = 0.5

  /// A participant's voice and the anchor turns it comes from.
  private struct Reference {
    var vector: [Double]
    var anchors: [Int]
    var turns: Int { anchors.count }
  }

  private struct Chunk {
    var start: Double
    var end: Double
    var vector: [Double]
    var seconds: Double { end - start }
  }

  private let segments: [TranscriptSegments.Segment]
  private let readings: [String?]
  private let participants: Set<String>?
  private var display: [String: String] = [:]
  private var coverage: [[String: Double]] = []
  private var onsets: [Set<String>] = []
  private var aligned: [Set<String>] = []
  private var chunks: [String: [Chunk]] = [:]
  private var touching: [[Int]] = []
  private var pure: [[Int]] = []
  /// The largest share of each turn that another voice's embedding spans.
  private var foreign: [Double] = []

  init(
    segments: [TranscriptSegments.Segment], timeline: SpeakingTimeline, excluded: [String],
    readings: [String?], embeddings: [TranscriptSegments.VoiceEmbedding],
    participants: [String]?
  ) {
    self.segments = segments
    self.readings = readings
    let excludedKeys = Set(excluded.map(Self.key))
    self.participants = participants.map { Set($0.map(Self.key)).subtracting(excludedKeys) }
    for name in readings.compactMap({ $0 }) {
      display[Self.key(name)] = display[Self.key(name)] ?? name
    }
    var shifted: [SpeakingTimeline.Interval] = []
    for interval in timeline.intervals {
      let name = interval.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = Self.key(name)
      guard !name.isEmpty, !excludedKeys.contains(key), interval.start.isFinite,
        interval.end.isFinite, interval.end >= interval.start
      else { continue }
      display[key] = display[key] ?? name
      let start = interval.start - SpeakerNaming.onsetDelay
      shifted.append(
        .init(
          name: key, start: start,
          end: max(start + SpeakerNaming.minimumInterval, interval.end - SpeakerNaming.releaseDelay)
        ))
    }
    let exclusive = Self.exclusive(shifted)
    coverage = segments.map { segment in
      guard segment.source == .teams else { return [:] }
      var seconds: [String: Double] = [:]
      for interval in exclusive {
        let overlap = min(segment.end, interval.end) - max(segment.start, interval.start)
        if overlap > 0 { seconds[interval.name, default: 0] += overlap }
      }
      return seconds
    }
    aligned = segments.map { segment in
      guard segment.source == .teams else { return [] }
      return Set(
        shifted.filter { abs($0.start - segment.start) <= Self.alignedOnset }.map(\.name))
    }
    onsets = segments.map { segment in
      guard segment.source == .teams else { return [] }
      return Set(
        shifted.filter {
          $0.start >= segment.start - Self.onsetLead && $0.start <= segment.end - Self.onsetTail
        }.map(\.name))
    }
    foreign = segments.map { _ in 0 }
    for embedding in embeddings where embedding.start.isFinite && embedding.end.isFinite {
      for (index, segment) in segments.enumerated()
      where Self.isVoice(segment) && segment.speaker != embedding.speaker {
        let overlap = min(segment.end, embedding.end) - max(segment.start, embedding.start)
        foreign[index] = max(foreign[index], overlap / SpeakerNaming.duration(segment))
      }
    }
    for embedding in embeddings {
      guard embedding.start.isFinite, embedding.end.isFinite,
        embedding.end - embedding.start >= Self.chunkSeconds,
        let vector = Self.normalized(embedding.values.map(Double.init))
      else { continue }
      chunks[embedding.speaker, default: []].append(
        Chunk(start: embedding.start, end: embedding.end, vector: vector))
    }
    let dimension = chunks.values.lazy.flatMap { $0 }.first?.vector.count
    chunks = chunks.mapValues { $0.filter { $0.vector.count == dimension } }
    touching = segments.map { _ in [] }
    pure = segments.map { _ in [] }
    let voices = Dictionary(grouping: segments.indices.filter { Self.isVoice(segments[$0]) }) {
      segments[$0].speaker
    }
    for (voice, turns) in voices {
      for (index, chunk) in (chunks[voice] ?? []).enumerated() {
        var overlaps: [(turn: Int, seconds: Double)] = []
        for turn in turns {
          let overlap = min(segments[turn].end, chunk.end) - max(segments[turn].start, chunk.start)
          if overlap > 0 { overlaps.append((turn, overlap)) }
        }
        let total = overlaps.reduce(0) { $0 + $1.seconds }
        for (turn, seconds) in overlaps where seconds >= 0.3 {
          touching[turn].append(index)
          if seconds >= 0.6 * total && seconds >= 1 { pure[turn].append(index) }
        }
      }
    }
  }

  func decisions() -> [Decision] {
    var result = readings.map { name in
      Decision(name: name, reason: name == nil ? .unidentified : .teamsReading)
    }
    let anchors = segments.indices.map(anchor)
    for (index, name) in anchors.enumerated() where name != nil { result[index].anchor = true }
    guard !chunks.isEmpty else {
      for index in segments.indices where Self.isVoice(segments[index]) {
        result[index].rejection = "no voice embeddings"
      }
      return result
    }
    let (references, quarantined) = references(anchors: anchors)
    let voices = Dictionary(grouping: segments.indices.filter { Self.isVoice(segments[$0]) }) {
      segments[$0].speaker
    }
    var notes: [Int: String] = [:]
    func note(_ turns: [Int], _ text: String) {
      for turn in turns where notes[turn] == nil { notes[turn] = text }
    }
    for (voice, turns) in voices.sorted(by: { $0.key < $1.key }) {
      let open = turns.filter { readings[$0] == nil }
      guard !open.isEmpty else { continue }
      if turns.contains(where: quarantined.contains) {
        note(open, "the voice has an anchor that sounds unlike its participant")
        continue
      }
      let anchored = Set(turns.compactMap { anchors[$0] })
      let read = Set(turns.compactMap { readings[$0].map(Self.key) })
      let additions: [(turn: Int, similarity: Double)]
      let reason: Reason
      let name: String
      if anchored.isEmpty && read.isEmpty {
        switch unindicatedMatch(voice: voice, turns: turns, references: references) {
        case .failure(let rejection):
          note(open, rejection.text)
          continue
        case .success(let match): (name, additions, reason) = (match.name, match.turns, .voiceMatch)
        }
      } else {
        guard anchored.count == 1, let only = anchored.first, read.isSubset(of: [only]) else {
          note(
            open,
            anchored.isEmpty
              ? "the voice has readings but no anchor" : "the voice shows several participants")
          continue
        }
        guard let reference = references[only] else {
          note(open, "no voice reference for \(display[only] ?? only)")
          continue
        }
        switch namedClusterMatches(
          voice: voice, turns: turns, name: only, anchors: anchors, references: references,
          reference: reference, notes: &notes)
        {
        case .failure(let rejection):
          note(open, rejection.text)
          continue
        case .success(let matches):
          (name, additions, reason) = (only, matches, .voiceOfNamedCluster)
        }
      }
      for (turn, similarity) in additions where readings[turn] == nil {
        guard foreign[turn] < Self.foreignVoice else {
          note(
            [turn], String(format: "another voice spans %.0f%% of the turn", 100 * foreign[turn]))
          continue
        }
        result[turn] = Decision(
          name: display[name], reason: reason, anchor: result[turn].anchor,
          similarity: similarity)
      }
    }
    for (turn, reading) in readings.enumerated() {
      guard let reading, Self.isVoice(segments[turn]) else { continue }
      switch correction(of: turn, reading: Self.key(reading), anchors: anchors) {
      case .failure(let rejection): notes[turn] = "no correction: " + rejection.text
      case .success(let correction):
        result[turn] = Decision(
          name: display[correction.name], reason: .voiceCorrection, anchor: result[turn].anchor,
          similarity: correction.similarity, reading: reading)
      }
    }
    for index in segments.indices where Self.isVoice(segments[index]) {
      let voice = segments[index].speaker
      let evidence = pure[index].isEmpty ? touching[index] : pure[index]
      let ranked = references.map { name, reference in
        (name: name, similarity: similarity(evidence, voice: voice, to: reference.vector))
      }.sorted { $0.similarity > $1.similarity }
      if let first = ranked.first, !evidence.isEmpty {
        result[index].candidate = display[first.name] ?? first.name
        result[index].candidateSimilarity = (first.similarity * 1000).rounded() / 1000
        result[index].runnerUpSimilarity = ranked.dropFirst().first.map {
          ($0.similarity * 1000).rounded() / 1000
        }
      }
      if result[index].reason == .unidentified || result[index].reason == .teamsReading {
        result[index].rejection =
          notes[index] ?? (evidence.isEmpty ? "no voice embedding of its own" : nil)
      }
    }
    return result
  }

  /// Why voice evidence did not decide a turn.
  struct Rejection: Error {
    let text: String
    init(_ text: String) { self.text = text }
  }

  /// Another participant for a turn whose reading the voice clearly contradicts. References
  /// are rebuilt without the turn and without any embedding overlapping it, so the turn cannot
  /// confirm itself; a Teams anchor that sounds like the participant's other anchors therefore
  /// never counts as contradicted. Every embedding must lead all other references by the
  /// margin, so at most one participant matches.
  private func correction(of turn: Int, reading: String, anchors: [String?])
    -> Result<(name: String, similarity: Double), Rejection>
  {
    let segment = segments[turn]
    guard foreign[turn] < Self.foreignVoice else {
      return .failure(
        Rejection(String(format: "another voice spans %.0f%% of the turn", 100 * foreign[turn])))
    }
    let speech = uniqueSeconds(pure[turn], voice: segment.speaker, within: segment)
    guard speech >= Self.correctionSpeech else {
      return .failure(Rejection(String(format: "only %.1f s of the turn's own speech", speech)))
    }
    func candidates(_ references: [String: Reference]) -> Result<
      (name: String, similarity: Double), Rejection
    > {
      guard let own = references[reading], own.turns >= Self.correctionReferences else {
        return .failure(Rejection("fewer than two independent references for the reading"))
      }
      let ownSimilarity = similarity(pure[turn], voice: segment.speaker, to: own.vector)
      guard ownSimilarity <= Self.contradiction else {
        return .failure(
          Rejection(String(format: "the voice resembles the reading (%.2f)", ownSimilarity)))
      }
      var failures: [String] = []
      var matches: [(name: String, similarity: Double)] = []
      for name in references.keys.sorted() where name != reading {
        guard references[name]!.turns >= Self.correctionReferences else { continue }
        switch match(
          pure[turn], voice: segment.speaker, name: name, references: references,
          rule: .correction)
        {
        case .success(let score): matches.append((name, score))
        case .failure(let rejection): failures.append("\(display[name] ?? name): \(rejection.text)")
        }
      }
      guard let match = matches.first else {
        return .failure(
          Rejection(
            failures.isEmpty
              ? "no other participant has two references"
              : "no participant matches clearly (" + failures.joined(separator: "; ") + ")"))
      }
      return .success(match)
    }
    return candidates(references(anchors: anchors, excluding: turn).references)
  }

  /// The participant whose indicator switched on during this turn and covers it clearly.
  private func anchor(_ index: Int) -> String? {
    let segment = segments[index]
    guard Self.isVoice(segment) else { return nil }
    let seconds = coverage[index]
    guard let (name, own) = seconds.max(by: { $0.value < $1.value }),
      own >= Self.anchorSeconds, own >= Self.anchorShare * SpeakerNaming.duration(segment),
      seconds.values.reduce(0, +) - own <= Self.anchorPurity * own, onsets[index].contains(name),
      readings[index].map({ Self.key($0) == name }) ?? true
    else { return nil }
    return name
  }

  /// Voice references from consistent anchors, and the anchors that contradict their name.
  /// With `excluding`, that turn and every embedding overlapping it contribute nothing.
  private func references(anchors: [String?], excluding: Int? = nil) -> (
    references: [String: Reference], quarantined: Set<Int>
  ) {
    var byName: [String: [(turn: Int, vector: [Double])]] = [:]
    var quarantined = Set<Int>()
    for (turn, name) in anchors.enumerated() where turn != excluding {
      guard let name else { continue }
      let voice = segments[turn].speaker
      let own = pure[turn].filter { index in
        guard let excluding else { return true }
        let chunk = chunks[voice]![index]
        return min(chunk.end, segments[excluding].end)
          <= max(chunk.start, segments[excluding].start)
      }
      if let vector = mean(own, voice: voice) {
        byName[name, default: []].append((turn, vector))
      }
    }
    var references: [String: Reference] = [:]
    for (name, anchored) in byName {
      var kept = anchored
      if anchored.count >= 2 {
        kept = anchored.filter { candidate in
          let others = anchored.filter { $0.turn != candidate.turn }.map(\.vector)
          return Self.mean(others).map { Self.cosine(candidate.vector, $0) }
            .map { $0 >= Self.anchorConsistency } ?? false
        }
        guard kept.count * 3 >= anchored.count * 2 else {
          quarantined.formUnion(anchored.map(\.turn))
          continue
        }
        quarantined.formUnion(
          anchored.map(\.turn).filter { turn in
            !kept.contains { $0.turn == turn }
          })
      }
      if let vector = Self.mean(kept.map(\.vector)) {
        references[name] = Reference(vector: vector, anchors: kept.map(\.turn))
      }
    }
    var ambiguous = Set<String>()
    let names = references.keys.sorted()
    for (offset, name) in names.enumerated() {
      for other in names[(offset + 1)...]
      where Self.cosine(references[name]!.vector, references[other]!.vector)
        >= Self.distinctReferences
      {
        ambiguous.formUnion([name, other])
      }
    }
    for name in ambiguous {
      references[name] = nil
      quarantined.formUnion(byName[name, default: []].map(\.turn))
    }
    return (references, quarantined)
  }

  /// Anonymous turns of a voice whose Teams evidence names one participant, with every
  /// embedding matching that participant's reference; turns that do not match get a note.
  private func namedClusterMatches(
    voice: String, turns: [Int], name: String, anchors: [String?],
    references: [String: Reference],
    reference: Reference, notes: inout [Int: String]
  ) -> Result<[(turn: Int, similarity: Double)], Rejection> {
    let speech = turns.reduce(0) { $0 + SpeakerNaming.duration(segments[$1]) }
    let anchored = turns.filter { anchors[$0] == name }.reduce(0) {
      $0 + coverage[$1][name, default: 0]
    }
    let indicated = turns.reduce(0) { $0 + coverage[$1].values.reduce(0, +) }
    let own = turns.reduce(0) { $0 + coverage[$1][name, default: 0] }
    if reference.turns < 2 {
      guard reference.anchors.allSatisfy(turns.contains) else {
        return .failure(Rejection("the only reference for the name comes from another voice"))
      }
      guard reference.anchors.allSatisfy({ aligned[$0].contains(name) }) else {
        return .failure(
          Rejection("the only anchor for the name switched on in the middle of the turn"))
      }
    }
    guard anchored >= Self.clusterSupport * speech else {
      return .failure(
        Rejection(String(format: "anchors cover %.1f s of the voice's %.0f s", anchored, speech)))
    }
    guard own >= Self.clusterShare * indicated else {
      return .failure(Rejection("Teams showed others for much of the voice"))
    }
    var result: [(turn: Int, similarity: Double)] = []
    for turn in turns where readings[turn] == nil {
      guard !touching[turn].isEmpty else {
        notes[turn] = "no voice embedding of its own"
        continue
      }
      switch match(
        touching[turn], voice: voice, name: name, references: references, rule: .namedVoice)
      {
      case .success(let score): result.append((turn, score))
      case .failure(let rejection): notes[turn] = rejection.text
      }
    }
    return .success(result)
  }

  private struct Rule {
    /// Minimum similarity of long and short embeddings, of their duration-weighted average,
    /// and the lead every embedding needs over all other references.
    var long: Double
    var short: Double
    var average: Double
    var margin: Double

    static let namedVoice = Rule(
      long: SpeakerFusion.clusterMatch, short: 0.4, average: 0.75,
      margin: SpeakerFusion.clusterMargin)
    static let unindicatedVoice = Rule(
      long: SpeakerFusion.voiceMatch, short: 0.5, average: SpeakerFusion.voiceAverage,
      margin: SpeakerFusion.voiceMargin)
    static let correction = Rule(
      long: SpeakerFusion.voiceMatch, short: 0.5, average: SpeakerFusion.voiceAverage,
      margin: SpeakerFusion.correctionMargin)
  }

  /// Embeddings of shorter speech than this only need the short similarity.
  static let longChunkSeconds = 5.0

  /// The similarity of these embeddings to `name`, if all of them fit it under `rule`.
  private func match(
    _ indices: [Int], voice: String, name: String,
    references: [String: Reference], rule: Rule
  ) -> Result<Double, Rejection> {
    guard let reference = references[name]?.vector else {
      return .failure(Rejection("no reference"))
    }
    guard !indices.isEmpty else { return .failure(Rejection("no embeddings")) }
    for index in indices {
      let chunk = chunks[voice]![index]
      let similarity = Self.cosine(chunk.vector, reference)
      let rival = references.filter { $0.key != name }.map {
        (name: $0.key, similarity: Self.cosine(chunk.vector, $0.value.vector))
      }.max { $0.similarity < $1.similarity }
      let floor = chunk.seconds >= Self.longChunkSeconds ? rule.long : rule.short
      guard similarity >= floor else {
        return .failure(
          Rejection(String(format: "an embedding is %.2f similar, below %.2f", similarity, floor)))
      }
      if let rival, similarity - rival.similarity < rule.margin {
        return .failure(
          Rejection(
            String(
              format: "an embedding leads %@ by only %.2f", display[rival.name] ?? rival.name,
              similarity - rival.similarity)))
      }
    }
    let average = similarity(indices, voice: voice, to: reference)
    guard average >= rule.average else {
      return .failure(
        Rejection(String(format: "average similarity %.2f, below %.2f", average, rule.average)))
    }
    return .success(average)
  }

  /// The similarity of embeddings to a reference, averaged over the speech they cover: where
  /// windows overlap, each shares the time with the others instead of counting it again.
  private func similarity(_ indices: [Int], voice: String, to reference: [Double]) -> Double {
    let weights = timeWeights(indices, voice: voice)
    let total = weights.reduce(0, +)
    guard total > 0 else { return 0 }
    return zip(indices, weights).reduce(0) {
      $0 + Self.cosine(chunks[voice]![$1.0].vector, reference) * $1.1
    } / total
  }

  /// Each embedding's share of the time the embeddings cover together.
  private func timeWeights(_ indices: [Int], voice: String) -> [Double] {
    let spans = indices.map { chunks[voice]![$0] }
    let bounds = Set(spans.flatMap { [$0.start, $0.end] }).sorted()
    var weights = [Double](repeating: 0, count: spans.count)
    for (start, end) in zip(bounds, bounds.dropFirst()) {
      let covering = spans.indices.filter { spans[$0].start <= start && spans[$0].end >= end }
      for index in covering { weights[index] += (end - start) / Double(covering.count) }
    }
    return weights
  }

  /// Seconds of `segment` the embeddings cover, each moment once.
  private func uniqueSeconds(
    _ indices: [Int], voice: String, within segment: TranscriptSegments.Segment
  ) -> Double {
    let spans = indices.map { chunks[voice]![$0] }.map {
      (max($0.start, segment.start), min($0.end, segment.end))
    }.filter { $0.0 < $0.1 }.sorted { $0.0 < $1.0 }
    var total = 0.0
    var reached = -Double.infinity
    for (start, end) in spans where end > reached {
      total += end - max(start, reached)
      reached = end
    }
    return total
  }

  /// A participant for a voice without any Teams evidence.
  private func unindicatedMatch(
    voice: String, turns: [Int], references: [String: Reference]
  ) -> Result<(name: String, turns: [(turn: Int, similarity: Double)]), Rejection> {
    guard let participants, !participants.isEmpty else {
      return .failure(Rejection("Teams never showed the full participant list"))
    }
    let unreferenced = participants.union(display.keys).subtracting(references.keys)
    guard unreferenced.isEmpty else {
      return .failure(
        Rejection(
          "no voice reference for "
            + unreferenced.sorted().map { display[$0] ?? $0 }.joined(separator: ", ")))
    }
    guard let voiceChunks = chunks[voice], voiceChunks.count >= 2,
      voiceChunks.reduce(0, { $0 + $1.seconds }) >= 2 * Self.chunkSeconds
    else { return .failure(Rejection("too little speech in the voice")) }
    let indicated = turns.reduce(0) { $0 + coverage[$1].values.reduce(0, +) }
    guard indicated <= Self.strayIndication else {
      return .failure(Rejection("Teams showed someone else during the voice"))
    }
    let all = Array(voiceChunks.indices)
    var failures: [String] = []
    var candidates: [(name: String, score: Double)] = []
    for name in references.keys.sorted() {
      switch match(all, voice: voice, name: name, references: references, rule: .unindicatedVoice) {
      case .success(let score): candidates.append((name, score))
      case .failure(let rejection): failures.append("\(display[name] ?? name): \(rejection.text)")
      }
    }
    guard let (name, score) = candidates.first else {
      return .failure(
        Rejection("no participant matches clearly (" + failures.joined(separator: "; ") + ")"))
    }
    guard references[name]!.turns >= 2 else {
      return .failure(Rejection("only one reference for \(display[name] ?? name)"))
    }
    return .success(
      (name, turns.filter { readings[$0] == nil && !touching[$0].isEmpty }.map { ($0, score) }))
  }

  private func mean(_ indices: [Int], voice: String) -> [Double]? {
    Self.mean(indices.map { chunks[voice]![$0].vector })
  }

  private static func isVoice(_ segment: TranscriptSegments.Segment) -> Bool {
    segment.source == .teams && segment.speaker != "unidentified"
  }

  /// Overlapping indicators are ambiguous, and duplicate readings cannot multiply evidence.
  private static func exclusive(_ intervals: [SpeakingTimeline.Interval])
    -> [SpeakingTimeline.Interval]
  {
    var changes: [Double: [String: Int]] = [:]
    for interval in intervals {
      changes[interval.start, default: [:]][interval.name, default: 0] += 1
      changes[interval.end, default: [:]][interval.name, default: 0] -= 1
    }
    var active: [String: Int] = [:]
    var previous: Double?
    var result: [SpeakingTimeline.Interval] = []
    for time in changes.keys.sorted() {
      if let previous, time > previous, active.count == 1, let name = active.keys.first {
        result.append(.init(name: name, start: previous, end: time))
      }
      for (name, delta) in changes[time]! {
        active[name, default: 0] += delta
        if active[name] == 0 { active[name] = nil }
      }
      previous = time
    }
    return result
  }

  static func key(_ name: String) -> String {
    SpeakerNaming.key(name.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func mean(_ vectors: [[Double]]) -> [Double]? {
    guard let first = vectors.first else { return nil }
    var sum = [Double](repeating: 0, count: first.count)
    for vector in vectors {
      for index in sum.indices { sum[index] += vector[index] }
    }
    return normalized(sum)
  }

  private static func normalized(_ vector: [Double]) -> [Double]? {
    guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm > 0, norm.isFinite else { return nil }
    return vector.map { $0 / norm }
  }

  private static func cosine(_ left: [Double], _ right: [Double]) -> Double {
    zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
  }
}

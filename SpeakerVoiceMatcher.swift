import Foundation

/// Matches turns against directly named acoustic references from this recording only.
/// A name needs both a sufficiently close voice and a clear lead over every other name.
/// References never grow from inferred identities, avoiding chains of self-confirming errors.
struct SpeakerVoiceMatcher {
  static let minimumSimilarity = 0.72
  static let minimumMargin = 0.08
  private static let minimumOverlap = 0.5

  private var queries: [Int: [(vector: [Double], weight: Double)]] = [:]
  private var references: [String: [[Double]]] = [:]

  init(
    segments: [TranscriptSegments.Segment], embeddings: [TranscriptSegments.VoiceEmbedding],
    anchors: [String?]
  ) {
    let grouped = Dictionary(grouping: segments.indices.filter { segments[$0].source == .teams }) {
      segments[$0].speaker
    }
    var referenceSamples: [String: [String: [[Double]]]] = [:]
    for embedding in embeddings {
      guard embedding.start.isFinite, embedding.end.isFinite, embedding.end > embedding.start,
        let vector = Self.normalized(embedding.values.map(Double.init))
      else { continue }
      var overlaps: [Int: Double] = [:]
      for index in grouped[embedding.speaker, default: []] {
        let segment = segments[index]
        let overlap = min(segment.end, embedding.end) - max(segment.start, embedding.start)
        if overlap > 0 { overlaps[index] = overlap }
      }
      let total = overlaps.values.reduce(0, +)
      guard total >= Self.minimumOverlap else { continue }
      for (turn, overlap) in overlaps
      where overlap >= Self.minimumOverlap && overlap >= total * 0.6 {
        queries[turn, default: []].append((vector, overlap))
      }
      let named = overlaps.compactMap { index, seconds in
        anchors[index].map { (name: $0, seconds: seconds, turn: index) }
      }
      let names = Set(named.map(\.name))
      guard names.count == 1, let name = names.first,
        named.reduce(0, { $0 + $1.seconds }) >= max(1.0, total * 0.6)
      else { continue }
      referenceSamples[name, default: [:]][embedding.speaker, default: []].append(vector)
    }
    for (name, voices) in referenceSamples {
      references[name] = voices.values.compactMap { vectors in
        guard let first = vectors.first else { return nil }
        let compatible = vectors.filter { $0.count == first.count }
        var sum = [Double](repeating: 0, count: first.count)
        for vector in compatible {
          for index in sum.indices { sum[index] += vector[index] }
        }
        return Self.normalized(sum)
      }
    }
  }

  func name(for turn: Int) -> String? {
    let vectors = queries[turn, default: []]
    guard !vectors.isEmpty else { return nil }
    var scores: [(name: String, score: Double)] = []
    for (name, references) in references {
      var weighted = 0.0
      var weight = 0.0
      for query in vectors {
        guard let similarity = references.compactMap({ Self.cosine(query.vector, $0) }).max()
        else { continue }
        weighted += similarity * query.weight
        weight += query.weight
      }
      if weight > 0 { scores.append((name, weighted / weight)) }
    }
    scores.sort { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
    guard let first = scores.first, first.score >= Self.minimumSimilarity,
      scores.count == 1 || first.score - scores[1].score >= Self.minimumMargin
    else { return nil }
    return first.name
  }

  private static func normalized(_ vector: [Double]) -> [Double]? {
    guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm > 0, norm.isFinite else { return nil }
    return vector.map { $0 / norm }
  }

  private static func cosine(_ left: [Double], _ right: [Double]) -> Double? {
    guard left.count == right.count else { return nil }
    return zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
  }
}

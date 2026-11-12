import Foundation

/// Voices of named remote speakers, kept across meetings so that a voice nothing in its own
/// recording names can take the name it had before.
///
/// A recording teaches a voice when Teams evidence named all of it: the diarizer voice of the
/// only remote participant, or a voice whose every turn carries one participant's name. A
/// name taken from a profile never teaches, so a wrong match cannot reinforce itself. Each
/// name keeps the voices of its most recent recordings side by side, because one person
/// sounds different through a headset, a laptop and a meeting room.
///
/// A voice takes a profile's name only when the whole voice resembles it at least `match` and
/// every other name at least `margin` less, and only for turns that would otherwise stay
/// anonymous.
struct VoiceProfiles: Codable, Equatable {
  struct Sample: Codable, Equatable {
    var vector: [Float]
    var seconds: Double
    var recordedAt: Date
  }

  struct Profile: Codable, Equatable {
    var name: String
    var samples: [Sample]
  }

  /// One voice's best profile.
  struct Match: Equatable {
    var name: String
    var similarity: Double
    var runnerUp: Double?
  }

  static let match = 0.8
  static let margin = 0.15
  /// The distinct speech a voice's embeddings must cover to be compared and to be learned.
  static let matchSpeech = 6.0
  static let learnSpeech = 10.0
  /// The share of the remote speech the only remote participant's voice must hold to be learned.
  static let soleVoiceShare = 0.9
  static let samplesPerName = 6
  /// Embeddings of shorter speech vary too much to compare voices.
  static let chunkSeconds = SpeakerFusion.chunkSeconds

  var profiles: [Profile] = []

  /// Each diarizer voice of the system track with enough speech: its direction and the
  /// distinct seconds its embeddings cover.
  static func voices(in result: TranscriptSegments) -> [String: (vector: [Double], seconds: Double)]
  {
    var sums: [String: [Double]] = [:]
    var spans: [String: [(Double, Double)]] = [:]
    for embedding in result.voiceEmbeddings ?? [] {
      let seconds = embedding.end - embedding.start
      guard embedding.start.isFinite, embedding.end.isFinite, seconds >= chunkSeconds,
        let vector = normalized(embedding.values.map(Double.init)),
        sums[embedding.speaker].map({ $0.count == vector.count }) ?? true
      else { continue }
      var sum = sums[embedding.speaker] ?? [Double](repeating: 0, count: vector.count)
      for index in sum.indices { sum[index] += vector[index] * seconds }
      sums[embedding.speaker] = sum
      spans[embedding.speaker, default: []].append((embedding.start, embedding.end))
    }
    var voices: [String: (vector: [Double], seconds: Double)] = [:]
    for (voice, sum) in sums {
      guard let vector = normalized(sum) else { continue }
      var seconds = 0.0
      var reached = -Double.infinity
      for (start, end) in spans[voice]!.sorted(by: { $0.0 < $1.0 }) where end > reached {
        seconds += end - max(start, reached)
        reached = end
      }
      voices[voice] = (vector, seconds)
    }
    return voices
  }

  /// The best profile for `vector` among the names `eligible` accepts (by `SpeakerNaming.key`),
  /// whatever its similarity.
  func best(for vector: [Double], eligible: (String) -> Bool = { _ in true }) -> Match? {
    var ranked: [(name: String, similarity: Double)] = []
    for profile in profiles where eligible(SpeakerNaming.key(profile.name)) {
      let similarities = profile.samples.compactMap { sample -> Double? in
        guard sample.vector.count == vector.count else { return nil }
        return zip(sample.vector, vector).reduce(0) { $0 + Double($1.0) * $1.1 }
      }
      if let similarity = similarities.max() { ranked.append((profile.name, similarity)) }
    }
    ranked.sort { $0.similarity > $1.similarity }
    guard let first = ranked.first else { return nil }
    return Match(
      name: first.name, similarity: first.similarity,
      runnerUp: ranked.count > 1 ? ranked[1].similarity : nil)
  }

  /// A name for each segment that `named` leaves anonymous and whose voice a profile matches.
  /// `named` holds the names the recording's own evidence gave; `excluded` names never match,
  /// and with `participants` (everyone Teams listed) only they can.
  func names(
    for result: TranscriptSegments, named: [String?], excluded: [String] = [],
    participants: [String]? = nil
  ) -> [String?] {
    var names = [String?](repeating: nil, count: result.segments.count)
    guard result.mode == .separateTracks, !profiles.isEmpty else { return names }
    let excludedKeys = Set(excluded.map(SpeakerNaming.key))
    let allowed = participants.map { Set($0.map(SpeakerNaming.key)) }
    let turns = Dictionary(grouping: result.segments.indices.filter { isRemote(result, $0) }) {
      result.segments[$0].speaker
    }
    for (voice, sample) in Self.voices(in: result) where sample.seconds >= Self.matchSpeech {
      guard let turns = turns[voice], turns.contains(where: { named[$0] == nil }),
        let match = best(
          for: sample.vector,
          eligible: { !excludedKeys.contains($0) && allowed?.contains($0) != false }),
        match.similarity >= Self.match,
        match.similarity - (match.runnerUp ?? -1) >= Self.margin
      else { continue }
      let key = SpeakerNaming.key(match.name)
      // Evidence in the recording that gave part of the voice another name outweighs a profile.
      guard turns.allSatisfy({ named[$0].map { SpeakerNaming.key($0) == key } ?? true }) else {
        continue
      }
      for turn in turns where named[turn] == nil { names[turn] = match.name }
    }
    return names
  }

  /// How each voice with anonymous turns compares with its best and next profile, without
  /// names, for the log: "S1=0.91/0.40".
  func comparison(for result: TranscriptSegments, named: [String?]) -> String {
    let anonymous = Set(
      result.segments.indices.filter { isRemote(result, $0) && named[$0] == nil }.map {
        result.segments[$0].speaker
      })
    return Self.voices(in: result).filter { anonymous.contains($0.key) }.sorted { $0.key < $1.key }
      .compactMap { voice, sample in
        best(for: sample.vector).map {
          String(format: "%@=%.2f/%.2f", voice, $0.similarity, $0.runnerUp ?? 0)
        }
      }.joined(separator: " ")
  }

  /// Adds the voices `named` names completely. `soleRemote` says the names come from being the
  /// only remote participant rather than from Teams showing who speaks. Returns whether
  /// anything was learned.
  @discardableResult
  mutating func learn(
    from result: TranscriptSegments, named: [String?], soleRemote: Bool, excluded: [String] = [],
    at date: Date
  ) -> Bool {
    guard result.mode == .separateTracks else { return false }
    let excludedKeys = Set(excluded.map(SpeakerNaming.key))
    let remote = result.segments.indices.filter { isRemote(result, $0) }
    let turns = Dictionary(grouping: remote) { result.segments[$0].speaker }
    let speech = { (turns: [Int]) in
      turns.reduce(0) { $0 + SpeakerNaming.duration(result.segments[$1]) }
    }
    let total = speech(remote)
    var learned = false
    for (voice, sample) in Self.voices(in: result) where sample.seconds >= Self.learnSpeech {
      guard let turns = turns[voice], let name = named[turns[0]],
        turns.allSatisfy({ named[$0] == name }), !excludedKeys.contains(SpeakerNaming.key(name)),
        !soleRemote || speech(turns) >= Self.soleVoiceShare * total
      else { continue }
      let entry = Sample(
        vector: sample.vector.map(Float.init), seconds: sample.seconds, recordedAt: date)
      if let index = profiles.firstIndex(where: {
        SpeakerNaming.key($0.name) == SpeakerNaming.key(name)
      }) {
        profiles[index].name = name
        profiles[index].samples.append(entry)
        profiles[index].samples = Array(profiles[index].samples.suffix(Self.samplesPerName))
      } else {
        profiles.append(Profile(name: name, samples: [entry]))
      }
      learned = true
    }
    return learned
  }

  private func isRemote(_ result: TranscriptSegments, _ index: Int) -> Bool {
    let segment = result.segments[index]
    return segment.source != .microphone && segment.speaker != "unidentified"
  }

  private static func normalized(_ vector: [Double]) -> [Double]? {
    guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm > 0, norm.isFinite else { return nil }
    return vector.map { $0 / norm }
  }
}

/// The voice profiles on disk, readable only by the user. Turning the setting off deletes them.
final class VoiceProfileStore: @unchecked Sendable {
  static let shared = VoiceProfileStore(file: defaultFile)

  /// `voices.json` in the app's Application Support folder, or in `MEETING_NOTES_CONFIG_DIR`
  /// for isolated runs.
  static var defaultFile: URL {
    let directory =
      ProcessInfo.processInfo.environment["MEETING_NOTES_CONFIG_DIR"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Meeting Notes", isDirectory: true)
    return directory.appendingPathComponent("voices.json")
  }

  let file: URL
  private let lock = NSLock()

  init(file: URL) { self.file = file }

  func load() -> VoiceProfiles {
    lock.withLock { read() }
  }

  /// Applies `change` to the stored profiles and saves them when it reports a change.
  func update(_ change: (inout VoiceProfiles) -> Bool) throws {
    try lock.withLock {
      var profiles = read()
      guard change(&profiles) else { return }
      let manager = FileManager.default
      try manager.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(profiles).write(to: file, options: .atomic)
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }

  func removeAll() {
    lock.withLock { try? FileManager.default.removeItem(at: file) }
  }

  private func read() -> VoiceProfiles {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: file),
      let profiles = try? decoder.decode(VoiceProfiles.self, from: data)
    else { return VoiceProfiles() }
    return profiles
  }
}

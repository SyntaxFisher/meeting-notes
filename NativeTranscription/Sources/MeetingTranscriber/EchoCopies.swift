import Foundation

/// Finds microphone words that repeat what the Teams track said at the same time: loudspeaker
/// echo the level-based `EchoFilter` kept because its loudness varies with the room.
///
/// Echo repeats remote speech word for word and at the same time, apart from the acoustic lag
/// and recognition differences, while local speech in double talk says something else, and
/// someone who agrees or repeats can only do so after hearing the words. A local word is a copy
/// when Teams was playing while it was spoken and it belongs to a run of at least `minimumRun`
/// words that match remote words in order: recognized at most `earlier` seconds before or
/// `later` seconds after them, allowing for the lag, and on average at most `alignment` seconds
/// after them, since nobody repeats words before hearing them; a run may pass over one differing
/// word, which goes with it only if it resembles the playback. In a local utterance that consists mostly of matches, counting shorter
/// aligned runs and single long words too, and that holds at least one aligned run, the
/// matches go as well, and so do stretches of at most `residueWords` other words between them
/// with a word that resembles the remote words, which are recognition noise of the same
/// playback; longer or entirely different stretches are someone speaking over the playback and
/// stay. Two people rarely say
/// the same three words at once, but often share a word or two, and a short utterance such as
/// a greeting or a farewell may be said together with the speaker, so it always stays.
enum EchoCopies {
  static let earlier = 1.0
  static let later = 0.9
  static let alignment = 0.6
  static let minimumRun = 3
  static let utteranceRun = 2
  static let utteranceShare = 0.7
  static let residueWords = 2
  /// Local utterances of at most this many words are never copies: people say greetings,
  /// farewells and confirmations together with the speaker, and nothing tells that from echo.
  static let chorus = 3
  /// Lone matches count toward an utterance only for words at least this long, recognized at
  /// most `earlier` seconds before or `loneLater` seconds after the remote word.
  static let longWord = 4
  static let loneLater = 0.25
  private static let localSkip = 1
  private static let remoteSkip = 2

  /// The microphone words of each chunk without copies of `remote`, and how many were removed.
  /// Without measured echo (`coupling` 0, as with headphones) nothing changes, and a word is
  /// never a copy while Teams was not `playing`.
  static func removing(
    from local: [[(word: SpeechPlan.Word, speaker: String)]], heard remote: [SpeechPlan.Word],
    coupling: Double, lag: Double = 0, playing: (SpeechPlan.Word) -> Bool
  ) -> (chunks: [[(word: SpeechPlan.Word, speaker: String)]], removed: Int) {
    guard coupling > 0 else { return (local, 0) }
    let copies = copied(
      local: local.flatMap { $0.map(\.word) }, remote: remote, lag: lag, playing: playing)
    var offset = 0
    let chunks = local.map { chunk in
      defer { offset += chunk.count }
      return chunk.enumerated().filter { !copies.contains(offset + $0.offset) }.map(\.element)
    }
    return (chunks, copies.count)
  }

  /// Indices into `local` of the words that copy `remote`.
  static func copied(
    local: [SpeechPlan.Word], remote: [SpeechPlan.Word], lag: Double = 0,
    playing: (SpeechPlan.Word) -> Bool
  ) -> Set<Int> {
    let order = local.indices.sorted { local[$0].start < local[$1].start }
    let tokens = order.map { token(local[$0].text) }
    let remoteOrder = remote.indices.sorted { remote[$0].start < remote[$1].start }
    var byToken: [String: [(position: Int, time: Double)]] = [:]
    for (position, index) in remoteOrder.enumerated() {
      let text = token(remote[index].text)
      if !text.isEmpty { byToken[text, default: []].append((position, middle(remote[index]))) }
    }
    let audible = order.map { playing(local[$0]) }
    var candidates: [[(position: Int, time: Double)]] = []
    for (position, index) in order.enumerated() {
      let time = middle(local[index]) - lag
      candidates.append(
        audible[position]
          ? byToken[tokens[position], default: []].filter {
            time - $0.time >= -earlier && time - $0.time <= later
          } : [])
    }
    let heard = remoteOrder.map { (time: middle(remote[$0]), token: token(remote[$0].text)) }
    func resemblesRemote(_ position: Int) -> Bool {
      let text = tokens[position]
      guard !text.isEmpty else { return false }
      let time = middle(local[order[position]]) - lag
      var lower = 0
      var upper = heard.count
      while lower < upper {
        let mid = (lower + upper) / 2
        if heard[mid].time < time - earlier { lower = mid + 1 } else { upper = mid }
      }
      return heard[lower...].prefix { $0.time <= time + later }.contains {
        resembles(text, $0.token)
      }
    }
    // runs[i][j]: the chain of matches ending with local word i on remote word j, with the sum
    // of their offsets from the lag, kept as a link to the previous match. A local word the chain
    // skips belongs to it only when it resembles the playback.
    struct Link {
      var previous: (position: Int, remote: Int)?
      var skipped: [Int]
      var length: Int
      var offsets: Double
    }
    var runs: [[Int: Link]] = order.map { _ in [:] }
    var copies = Set<Int>()
    var paired = Set<Int>()
    var inCopies = Set<[Int]>()
    var inPaired = Set<[Int]>()
    /// Adds the words of the chain ending at `end` to `words`, stopping at the part an earlier
    /// chain already added.
    func add(_ end: (position: Int, remote: Int), to words: inout Set<Int>, done: inout Set<[Int]>)
    {
      var state: (position: Int, remote: Int)? = end
      while let current = state, done.insert([current.position, current.remote]).inserted {
        let link = runs[current.position][current.remote]!
        words.insert(current.position)
        words.formUnion(link.skipped)
        state = link.previous
      }
    }
    for position in order.indices {
      let time = middle(local[order[position]]) - lag
      for candidate in candidates[position] {
        let offset = time - candidate.time
        var best = Link(previous: nil, skipped: [], length: 1, offsets: offset)
        for previous in max(0, position - 1 - localSkip)..<position
        where local[order[position]].start - local[order[previous]].end <= SpeechPlan.segmentPause {
          for (remotePosition, run) in runs[previous]
          where remotePosition < candidate.position
            && candidate.position - remotePosition <= 1 + remoteSkip && run.length + 1 > best.length
          {
            best = Link(
              previous: (previous, remotePosition),
              skipped: (previous + 1..<position).filter(resemblesRemote), length: run.length + 1,
              offsets: run.offsets + offset)
          }
        }
        runs[position][candidate.position] = best
        guard best.offsets / Double(best.length) <= alignment else { continue }
        let end = (position: position, remote: candidate.position)
        if best.length >= utteranceRun { add(end, to: &paired, done: &inPaired) }
        if best.length >= minimumRun { add(end, to: &copies, done: &inCopies) }
      }
    }
    var utterance: [Int] = []
    func close() {
      let words = utterance.filter { !tokens[$0].isEmpty }
      let matched = words.filter { position in
        paired.contains(position)
          || (tokens[position].count >= longWord
            && candidates[position].contains {
              middle(local[order[position]]) - lag - $0.time <= loneLater
            })
      }
      if words.contains(where: paired.contains),
        Double(matched.count) >= utteranceShare * Double(words.count)
      {
        let matchedSet = Set(matched)
        var residue: [Int] = []
        func flush() {
          if residue.filter({ !tokens[$0].isEmpty }).count <= residueWords,
            residue.contains(where: resemblesRemote)
          {
            copies.formUnion(residue)
          }
          residue = []
        }
        for position in utterance {
          if matchedSet.contains(position) || copies.contains(position) {
            flush()
            copies.insert(position)
          } else {
            residue.append(position)
          }
        }
        flush()
      }
      if words.count <= chorus { copies.subtract(utterance) }
      utterance = []
    }
    for position in order.indices {
      if let last = utterance.last,
        local[order[position]].start - local[order[last]].end > SpeechPlan.segmentPause
      {
        close()
      }
      utterance.append(position)
    }
    close()
    return Set(copies.filter { audible[$0] }.map { order[$0] })
  }

  /// Whether a local word may be a misrecognized echo of a remote one: the same word, a number,
  /// or a word of at least three letters that begins like it and differs by at most one letter,
  /// or two from five letters on. Short words two letters apart, such as "Nein" and "new", are
  /// different words.
  static func resembles(_ local: String, _ remote: String) -> Bool {
    if local == remote || local.contains(where: \.isNumber) || remote.contains(where: \.isNumber) {
      return true
    }
    let shorter = min(local.count, remote.count)
    guard shorter >= 3, local.first == remote.first else { return false }
    return local.hasPrefix(remote) || remote.hasPrefix(local)
      || distance(local, remote) <= (shorter >= 5 ? 2 : 1)
  }

  private static func distance(_ left: String, _ right: String) -> Int {
    let left = Array(left)
    let right = Array(right)
    var previous = Array(0...right.count)
    for (i, a) in left.enumerated() {
      var current = [i + 1]
      for (j, b) in right.enumerated() {
        current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (a == b ? 0 : 1)))
      }
      previous = current
    }
    return previous[right.count]
  }

  private static func middle(_ word: SpeechPlan.Word) -> Double {
    (word.start + word.end) / 2
  }

  static func token(_ text: String) -> String {
    String(
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
  }
}

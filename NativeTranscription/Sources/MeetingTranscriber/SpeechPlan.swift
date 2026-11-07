import Foundation

/// Decides which audio of one track whisper transcribes and attributes the timed words it returns
/// to diarized speakers.
///
/// Whisper only sees voice activity. Speech regions become passages of one speaker, and each
/// passage gets its own detected language. Consecutive passages are packed in time order into
/// chunks of at most `maximumChunkSeconds` until the language changes, so whisper hears the
/// conversation as it happened, needs few 30-second windows, and is never told the wrong language
/// for a speaker who switches. Pauses up to `keptPause` stay as recorded; longer ones become
/// `joinedSilence`, because whisper invents text in long silence.
///
/// Every word belongs to the passage it falls in and so to that passage's speaker: diarizer turns
/// often start more than a second late, while voice activity marks the real start.
enum SpeechPlan {
  static let maximumChunkSeconds = 28.0
  /// Padding around each region, at most half the pause to the neighboring region.
  static let regionPadding = 0.2
  /// Pauses between regions of one speaker up to this length stay inside a passage.
  static let bridgedPause = 0.15
  /// Pauses between passages up to this length stay in a chunk as recorded.
  static let keptPause = 1.5
  /// What longer pauses become: long enough to keep imprecise word times on the right side of
  /// the join, short enough that whisper does not invent text in it.
  static let joinedSilence = 1.0
  /// Passages shorter than this are too short to tell their language and join any chunk.
  static let minimumLanguageSeconds = 2.0
  /// The shortest a word counts as when it is attributed.
  static let minimumWordSeconds = 0.1
  /// Words further apart than this start a new segment.
  static let segmentPause = 1.0
  /// How long words inside another speaker's turn must last to leave their passage's speaker.
  static let overrideSeconds = 0.8
  /// How far before a turn's start and after its end a word still counts as inside it.
  static let overrideLead = 0.5
  static let overrideTrail = 0.3

  struct Region: Equatable {
    var start: Double
    var end: Double
  }

  struct Turn: Equatable {
    var start: Double
    var end: Double
    var speaker: String
  }

  /// Detected speech remains transcribable even when no voice could be clustered.
  static func unidentifiedTurns(in regions: [Region]) -> [Turn] {
    regions.map { Turn(start: $0.start, end: $0.end, speaker: "unidentified") }
  }

  /// How speech outside every turn is attributed.
  struct Policy: Equatable {
    /// Speech up to this many seconds before a turn belongs to it.
    var lead: Double
    /// Speech up to this many seconds after a turn belongs to it.
    var trail: Double
    /// Speech farther from every turn goes to the nearest turn instead of being dropped.
    var keepsDistantSpeech: Bool

    /// Remote voices and mixed recordings: every recognized word belongs to someone.
    static let speakers = Policy(lead: 1.0, trail: 0.5, keepsDistantSpeech: true)
    /// The microphone track, whose turns are the local speech left after echo filtering:
    /// speech far from it is Teams playback picked up by the microphone.
    static let localSpeech = Policy(lead: 0.6, trail: 0.3, keepsDistantSpeech: false)
  }

  /// A stretch of one speaker's speech: padded speech regions with short pauses kept.
  struct Passage: Equatable {
    var start: Double
    var end: Double
    var speaker: String
  }

  /// A passage placed at `offset` seconds in its chunk.
  struct Piece: Equatable {
    var passage: Passage
    var offset: Double

    var endOffset: Double { offset + passage.end - passage.start }
  }

  struct Chunk: Equatable {
    /// The language whisper is told to transcribe; nil lets it detect the language itself.
    var language: String?
    var pieces: [Piece]

    var duration: Double { pieces.last?.endOffset ?? 0 }

    /// The piece a chunk time belongs to; times between pieces go to the nearer one.
    func pieceIndex(at time: Double) -> Int {
      for (index, piece) in pieces.enumerated() where time < piece.offset {
        guard index > 0 else { return 0 }
        return time - pieces[index - 1].endOffset < piece.offset - time ? index - 1 : index
      }
      return max(0, pieces.count - 1)
    }

    /// Moves words from chunk time to track time and attributes each to the speaker of its
    /// piece. A word lands in one piece, chosen by its middle and never earlier than the previous
    /// word's, because whisper's word times are imprecise near joins while its word order is right.
    func place(_ words: [Word]) -> [(word: Word, speaker: String)] {
      var minimum = 0
      return words.map { word in
        let index = max(minimum, pieceIndex(at: (word.start + word.end) / 2))
        minimum = index
        let passage = pieces[index].passage
        let offset = pieces[index].offset
        func track(_ time: Double) -> Double {
          min(passage.end, max(passage.start, passage.start + time - offset))
        }
        return (
          Word(start: track(word.start), end: track(word.end), text: word.text), passage.speaker
        )
      }
    }
  }

  /// A recognized word on the track's timeline.
  struct Word: Equatable {
    var start: Double
    var end: Double
    var text: String
  }

  struct Segment: Equatable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
  }

  /// The speaker of a region: whoever talks most in it, counting turns from the policy's lead
  /// before they start to its trail after they end; else the nearest turn if the policy keeps
  /// distant speech.
  static func speaker(of region: Region, turns: [Turn], policy: Policy) -> String? {
    var overlap: [String: Double] = [:]
    for turn in turns {
      let seconds =
        min(region.end, turn.end + policy.trail) - max(region.start, turn.start - policy.lead)
      if seconds > 0 { overlap[turn.speaker, default: 0] += seconds }
    }
    if let dominant = overlap.max(by: {
      $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key)
    }) {
      return dominant.key
    }
    guard policy.keepsDistantSpeech else { return nil }
    let middle = (region.start + region.end) / 2
    return turns.min { distance(middle, $0) < distance(middle, $1) }?.speaker
  }

  private static func distance(_ time: Double, _ turn: Turn) -> Double {
    max(0, turn.start - time, time - turn.end)
  }

  /// Repairs a diarizer artifact. The diarizer labels overlapping windows that start every
  /// `windowStep` seconds, and where two windows disagree it switches speakers exactly on a window
  /// edge without a pause. A turn shorter than `artifactSeconds` that meets another speaker's turn
  /// that way belongs to that neighbor.
  static func repairedTurns(_ turns: [Turn], windowStep: Double) -> [Turn] {
    let artifactSeconds = 2.0
    let tolerance = 0.02
    var turns = turns.sorted { $0.start < $1.start }
    func onWindowEdge(_ time: Double) -> Bool {
      let offset = time.truncatingRemainder(dividingBy: windowStep)
      return min(offset, windowStep - offset) <= tolerance
    }
    func meets(_ first: Turn, _ second: Turn) -> Bool {
      first.speaker != second.speaker && abs(first.end - second.start) <= tolerance
        && onWindowEdge(second.start)
    }
    for index in turns.indices where turns[index].end - turns[index].start < artifactSeconds {
      let previous = index > 0 && meets(turns[index - 1], turns[index]) ? turns[index - 1] : nil
      let next =
        index + 1 < turns.count && meets(turns[index], turns[index + 1]) ? turns[index + 1] : nil
      let neighbor = [previous, next].compactMap { $0 }.max {
        $0.end - $0.start < $1.end - $1.start
      }
      if let neighbor, neighbor.end - neighbor.start >= artifactSeconds {
        turns[index].speaker = neighbor.speaker
      }
    }
    return turns
  }

  /// Turns the speech regions of one track into passages. Regions the policy attributes to
  /// nobody are dropped.
  static func passages(regions: [Region], turns: [Turn], policy: Policy, trackDuration: Double)
    -> [Passage]
  {
    let regions = regions.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    var passages: [Passage] = []
    for (index, region) in regions.enumerated() {
      guard let speaker = speaker(of: region, turns: turns, policy: policy) else { continue }
      let previousEnd = index > 0 ? regions[index - 1].end : -Double.infinity
      let nextStart = index + 1 < regions.count ? regions[index + 1].start : Double.infinity
      let start = max(0, region.start - min(regionPadding, (region.start - previousEnd) / 2))
      let end = min(trackDuration, region.end + min(regionPadding, (nextStart - region.end) / 2))
      guard end > start else { continue }
      if let last = passages.last, last.speaker == speaker, start - last.end <= bridgedPause,
        end - last.start <= maximumChunkSeconds
      {
        passages[passages.count - 1].end = end
      } else {
        passages.append(Passage(start: start, end: end, speaker: speaker))
      }
    }
    return passages
  }

  /// Packs passages into chunks. `languages[i]` is the detected language of `passages[i]`, or nil
  /// when the passage is too short to tell.
  static func chunks(passages: [Passage], languages: [String?]) -> [Chunk] {
    var chunks: [Chunk] = []
    for (passage, language) in zip(passages, languages) {
      if var chunk = chunks.last, let last = chunk.pieces.last,
        language == nil || chunk.language == nil || language == chunk.language
      {
        let pause = passage.start - last.passage.end
        let offset = last.endOffset + (pause <= keptPause ? max(0, pause) : joinedSilence)
        if offset + passage.end - passage.start <= maximumChunkSeconds {
          chunk.pieces.append(Piece(passage: passage, offset: offset))
          chunk.language = chunk.language ?? language
          chunks[chunks.count - 1] = chunk
          continue
        }
      }
      chunks.append(Chunk(language: language, pieces: [Piece(passage: passage, offset: 0)]))
    }
    return chunks
  }

  /// Joins consecutive words of one speaker into segments. A stretch of at least
  /// `overrideSeconds` inside another speaker's turn goes to that speaker: two people talking
  /// without a pause, so voice activity could not separate them. Under a policy that drops
  /// distant speech, words far from every turn are dropped.
  static func segments(words placed: [(word: Word, speaker: String)], turns: [Turn], policy: Policy)
    -> [Segment]
  {
    let words = placed.map(\.word)
    var speakers: [String?] = placed.map { word, speaker in
      // whisper gives some words no duration; they still need an overlap to be attributed.
      let middle = (word.start + word.end) / 2
      let region = Region(
        start: min(word.start, middle - minimumWordSeconds / 2),
        end: max(word.end, middle + minimumWordSeconds / 2))
      return policy.keepsDistantSpeech
        || self.speaker(of: region, turns: turns, policy: policy) != nil
        ? speaker : nil
    }
    // Where turns overlap, the one that started last is the speaker who just began talking.
    let containing = words.map { word in
      let middle = (word.start + word.end) / 2
      return turns.filter {
        $0.start - overrideLead <= middle && middle <= $0.end + overrideTrail
      }.max { $0.start < $1.start }?.speaker
    }
    var index = 0
    while index < words.count {
      guard let other = containing[index], speakers[index] != nil, other != speakers[index] else {
        index += 1
        continue
      }
      var last = index
      while last + 1 < words.count, containing[last + 1] == other, speakers[last + 1] != nil {
        last += 1
      }
      if words[last].end - words[index].start >= overrideSeconds {
        for position in index...last { speakers[position] = other }
      }
      index = last + 1
    }
    var segments: [Segment] = []
    var previous: String?
    for (word, speaker) in zip(words, speakers) {
      guard let speaker else {
        previous = nil
        continue
      }
      if speaker == previous, var last = segments.last, word.start - last.end <= segmentPause {
        last.end = max(last.end, word.end)
        last.text += word.text
        segments[segments.count - 1] = last
      } else {
        segments.append(
          Segment(start: word.start, end: word.end, speaker: speaker, text: word.text))
      }
      previous = speaker
    }
    return segments.compactMap {
      var segment = $0
      segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return segment.text.isEmpty ? nil : segment
    }
  }
}

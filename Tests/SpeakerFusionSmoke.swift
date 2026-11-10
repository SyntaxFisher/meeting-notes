import Foundation

enum SpeakerFusionSmoke {
  private struct Turn {
    var start: Double
    var end: Double
    var voice: String
    var person: String
  }

  private struct Random {
    var state: UInt64
    mutating func next() -> Double {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(state >> 11) / Double(1 << 53)
    }
  }

  private static func unit(_ values: [Double]) -> [Double] {
    let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
    return values.map { $0 / norm }
  }

  /// Voices with a shared component, so that different people are `similarity` alike.
  private static func voices(_ people: [String], similarity: Double, seed: UInt64) -> [String:
    [Double]]
  {
    var random = Random(state: seed)
    let shared = unit((0..<32).map { _ in random.next() - 0.5 })
    var result: [String: [Double]] = [:]
    for person in people {
      let own = unit((0..<32).map { _ in random.next() - 0.5 })
      result[person] = unit(
        zip(shared, own).map { sqrt(similarity) * $0 + sqrt(1 - similarity) * $1 })
    }
    return result
  }

  /// FluidAudio-like embeddings: 10 s windows every 2 s, one per voice and person in a window,
  /// spanning that person's speech in it.
  private static func embeddings(_ turns: [Turn], voices: [String: [Double]], seed: UInt64 = 1)
    -> [TranscriptSegments.VoiceEmbedding]
  {
    var random = Random(state: seed)
    var result: [TranscriptSegments.VoiceEmbedding] = []
    let end = turns.map(\.end).max() ?? 0
    var window = 0.0
    while window < end {
      var spans: [String: (start: Double, end: Double, voice: String, person: String)] = [:]
      for turn in turns where turn.end > window && turn.start < window + 10 {
        let key = turn.voice + "|" + turn.person
        let start = max(window, turn.start)
        let stop = min(window + 10, turn.end)
        let span = spans[key]
        spans[key] = (
          min(span?.start ?? start, start), max(span?.end ?? stop, stop), turn.voice, turn.person
        )
      }
      for span in spans.values.sorted(by: { $0.voice + $0.person < $1.voice + $1.person }) {
        let noise = unit((0..<32).map { _ in random.next() - 0.5 })
        let vector = unit(zip(voices[span.person]!, noise).map { $0 + 0.25 * $1 })
        result.append(
          .init(
            speaker: span.voice, start: span.start, end: span.end,
            values: vector.map(Float.init)))
      }
      window += 2
    }
    return result
  }

  private static func segments(_ turns: [Turn]) -> [TranscriptSegments.Segment] {
    turns.map {
      .init(start: $0.start, end: $0.end, source: .teams, speaker: $0.voice, text: $0.person)
    }
  }

  private static func shown(_ name: String, _ start: Double, _ end: Double)
    -> SpeakingTimeline.Interval
  {
    .init(
      name: name, start: start + SpeakerNaming.onsetDelay,
      end: end + SpeakerNaming.releaseDelay)
  }

  static func run() throws {
    let people = ["Anna", "Sam", "Bob"]
    let distinct = voices(people, similarity: 0.1, seed: 3)

    // Teams shows Anna only briefly at the start of her first turn and clearly later.
    let sparse = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Sam"),
      Turn(start: 40, end: 52, voice: "S1", person: "Anna"),
      Turn(start: 54, end: 58, voice: "S1", person: "Anna"),
      Turn(start: 60, end: 72, voice: "S2", person: "Sam"),
    ]
    let sparseTimeline = SpeakingTimeline(intervals: [
      shown("Anna", 0, 0.5), shown("Sam", 14, 26), shown("Anna", 54, 58), shown("Sam", 60, 72),
    ])
    precondition(
      SpeakerNaming.names(for: segments(sparse), timeline: sparseTimeline)
        == [nil, "Sam", nil, "Anna", "Sam"], "Readings alone leave sparsely shown speech anonymous")
    let fused = SpeakerNaming.decisions(
      for: segments(sparse), timeline: sparseTimeline,
      embeddings: embeddings(sparse, voices: distinct))
    precondition(
      fused.map(\.name) == ["Anna", "Sam", "Anna", "Anna", "Sam"],
      "A clear later indication names the rest of a voice that sounds the same")
    precondition(
      fused.map(\.reason) == [
        .voiceOfNamedCluster, .teamsReading, .voiceOfNamedCluster, .teamsReading, .teamsReading,
      ])

    // Random meetings with misclustered turns and wrong, late or stuck indicators: every name
    // voice evidence adds or changes must be the person who spoke.
    var random = Random(state: 11)
    var added = 0
    var changed = 0
    func checkRandom(_ turns: [Turn], _ intervals: [SpeakingTimeline.Interval], seed: UInt64) {
      let timeline = SpeakingTimeline(intervals: intervals)
      let readings = SpeakerNaming.readingNames(for: segments(turns), timeline: timeline)
      let decisions = SpeakerNaming.decisions(
        for: segments(turns), timeline: timeline,
        embeddings: embeddings(turns, voices: distinct, seed: seed), participants: people)
      for (index, (reading, decision)) in zip(readings, decisions).enumerated()
      where reading != decision.name {
        precondition(
          decision.name == turns[index].person
            && (reading == nil
              || (decision.reason == .voiceCorrection && decision.reading == reading)),
          "Voice evidence names only the person who spoke: \(turns[index]) \(decision)")
        if reading == nil { added += 1 } else { changed += 1 }
      }
    }
    for round in 0..<200 {
      var turns: [Turn] = []
      var intervals: [SpeakingTimeline.Interval] = []
      var time = 0.0
      for _ in 0..<12 {
        let person = people[Int(random.next() * 3)]
        let voice =
          random.next() < 0.2
          ? "S\(Int(random.next() * 3) + 1)" : "S\(people.firstIndex(of: person)! + 1)"
        let length = 1 + random.next() * 12
        turns.append(Turn(start: time, end: time + length, voice: voice, person: person))
        if random.next() < 0.5 {
          let shownName = random.next() < 0.2 ? people[Int(random.next() * 3)] : person
          let start = time + random.next() * length
          intervals.append(
            shown(
              shownName, start, min(time + length + random.next() * 3, start + random.next() * 10)))
        }
        time += length + random.next() * 2
      }
      checkRandom(turns, intervals, seed: UInt64(round))
    }
    // Long turns Teams mostly shows on time, while the previous speaker's indicator sometimes
    // stays on through the next turn.
    for round in 0..<200 {
      var turns: [Turn] = []
      var intervals: [SpeakingTimeline.Interval] = []
      var time = 0.0
      for index in 0..<14 {
        let person = people[index < 6 ? index % 3 : Int(random.next() * 3)]
        let length = 7 + random.next() * 8
        turns.append(
          Turn(
            start: time, end: time + length, voice: "S\(people.firstIndex(of: person)! + 1)",
            person: person))
        if index > 0, index >= 6, random.next() < 0.3, turns[index - 1].person != person {
          intervals.append(shown(turns[index - 1].person, time - 3, time + length))
        } else if index < 6 || random.next() < 0.6 {
          intervals.append(shown(person, time, time + length))
        }
        time += length + 0.5 + random.next()
      }
      checkRandom(turns, intervals, seed: UInt64(1000 + round))
    }
    precondition(added > 0 && changed > 0, "The random meetings exercise additions and corrections")

    // Anna's short interjection lands in Bob's diarizer voice without an embedding of its own.
    let interjection = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Bob"),
      Turn(start: 28, end: 40, voice: "S1", person: "Anna"),
      Turn(start: 42, end: 54, voice: "S2", person: "Bob"),
      Turn(start: 70, end: 71.5, voice: "S2", person: "Anna"),
      Turn(start: 80, end: 170, voice: "S2", person: "Bob"),
    ]
    let interjectionDecision = SpeakerNaming.decisions(
      for: segments(interjection),
      timeline: .init(intervals: interjection.prefix(4).map { shown($0.person, $0.start, $0.end) }),
      embeddings: embeddings(interjection, voices: distinct).filter {
        $0.start >= 72 || $0.end <= 69
      }, participants: ["Anna", "Bob"])[4]
    precondition(
      interjectionDecision.name == nil
        && interjectionDecision.rejection == "no voice embedding of its own",
      "A turn without an embedding of its own takes no name from its cluster")

    // Teams falsely shows Anna once, in the middle of a turn of Bob, whom it never shows.
    let midTurn = [
      Turn(start: 0, end: 12, voice: "S1", person: "Bob"),
      Turn(start: 14, end: 40, voice: "S1", person: "Bob"),
      Turn(start: 42, end: 80, voice: "S1", person: "Bob"),
    ]
    let midTurnNames = SpeakerNaming.decisions(
      for: segments(midTurn), timeline: .init(intervals: [shown("Anna", 3, 12)]),
      embeddings: embeddings(midTurn, voices: distinct))
    precondition(
      midTurnNames.map(\.name) == ["Anna", nil, nil]
        && midTurnNames[1].rejection?.contains("middle of the turn") == true,
      "One indicator that switched on mid-turn names no other turn: \(midTurnNames)")
    // Anna's only usable reference is a false indicator on Bob in another voice; her own short
    // turn in this voice has no embedding, and Bob's turn was misclustered into it.
    let borrowed = [
      Turn(start: 0, end: 12, voice: "S1", person: "Bob"),
      Turn(start: 14, end: 16.5, voice: "S2", person: "Anna"),
      Turn(start: 20, end: 35, voice: "S2", person: "Bob"),
    ]
    let borrowedNames = SpeakerNaming.decisions(
      for: segments(borrowed),
      timeline: .init(intervals: [shown("Anna", 0, 12), shown("Anna", 14, 16.5)]),
      embeddings: embeddings(borrowed, voices: distinct))
    precondition(
      borrowedNames.map(\.name) == ["Anna", "Anna", nil]
        && borrowedNames[2].rejection?.contains("another voice") == true,
      "A single anchor in another voice names nothing: \(borrowedNames)")

    // Anna's indicator lingers into the replies of Bob, who sounds like her and never appears.
    let alike = voices(["Anna", "Bob"], similarity: 0.85, seed: 9)
    let lingering = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 12.2, end: 14.2, voice: "S2", person: "Bob"),
      Turn(start: 30, end: 42, voice: "S1", person: "Anna"),
      Turn(start: 42.2, end: 44.2, voice: "S2", person: "Bob"),
      Turn(start: 60, end: 80, voice: "S2", person: "Bob"),
    ]
    let lingeringTimeline = SpeakingTimeline(intervals: [
      .init(name: "Anna", start: 1.1, end: 16.6), .init(name: "Anna", start: 31.1, end: 46.6),
    ])
    precondition(
      SpeakerNaming.names(
        for: segments(lingering), timeline: lingeringTimeline,
        embeddings: embeddings(lingering, voices: alike))[4] == nil,
      "An indicator that continues from the previous turn is not evidence for the next voice")

    // Teams shows Anna once, falsely, during Bob, and never shows Bob.
    let unsupported = [
      Turn(start: 0, end: 3, voice: "S2", person: "Bob"),
      Turn(start: 15, end: 45, voice: "S2", person: "Bob"),
      Turn(start: 47, end: 77, voice: "S2", person: "Bob"),
    ]
    precondition(
      SpeakerNaming.names(
        for: segments(unsupported), timeline: .init(intervals: [shown("Anna", 0.5, 2.5)]),
        embeddings: embeddings(unsupported, voices: distinct)) == ["Anna", nil, nil],
      "One short indication does not name a voice that mostly spoke without it")

    // Handmade embeddings: Eve and Bob share Anna's diarizer voice and are never shown.
    func vector(_ values: [Float]) -> [Float] {
      let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
      return values.map { $0 / norm }
    }
    let handmade = [
      Turn(start: 0, end: 4, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Sam"),
      Turn(start: 28, end: 32, voice: "S1", person: "Anna"),
      Turn(start: 42, end: 54, voice: "S2", person: "Sam"),
      Turn(start: 56, end: 96, voice: "S1", person: "Eve"),
    ]
    let handmadeTimeline = SpeakingTimeline(
      intervals: handmade.prefix(4).map {
        shown($0.person, $0.start, $0.end)
      })
    let pieces: [(Double, Double, String, [Float])] = [
      (0, 4, "S1", [1, 0, 0]), (14, 26, "S2", [0, 1, 0]), (28, 32, "S1", [1, 0.02, 0]),
      (42, 54, "S2", [0.02, 1, 0]),
    ]
    func eve(_ extra: [(Double, Double, [Float])]) -> String? {
      let embeddings = (pieces + extra.map { ($0.0, $0.1, "S1", $0.2) }).map {
        TranscriptSegments.VoiceEmbedding(
          speaker: $0.2, start: $0.0, end: $0.1, values: vector($0.3))
      }
      return SpeakerNaming.names(
        for: segments(handmade), timeline: handmadeTimeline, embeddings: embeddings)[4]
    }
    precondition(eve([(56, 96, [1, 0.01, 0.01])]) == "Anna", "A matching voice takes the name")
    precondition(eve([(56, 96, [0.78, 0.68, 0])]) == nil, "A voice between two people is no match")
    precondition(
      eve([(56, 90, [1, 0, 0]), (90, 96, [0.5, 0, 0.866])]) == nil,
      "A turn with any long embedding unlike the participant stays anonymous")
    precondition(
      eve([(56, 96, [0.71, 0, 0.704])]) == nil, "A weak overall resemblance is no match")
    let overheard = (pieces + [(56, 96, "S1", [1, 0.01, 0.01]), (60, 80, "S4", [0, 0, 1])]).map {
      TranscriptSegments.VoiceEmbedding(
        speaker: $0.2, start: $0.0, end: $0.1, values: vector($0.3))
    }
    precondition(
      SpeakerNaming.names(
        for: segments(handmade), timeline: handmadeTimeline, embeddings: overheard)[4] == nil,
      "A turn where FluidAudio also heard another voice stays anonymous")

    // Bob, never shown, shares Anna's diarizer voice.
    let merged = (0..<8).map { index in
      Turn(
        start: Double(index) * 10, end: Double(index) * 10 + 8, voice: "S1",
        person: index % 2 == 0 ? "Anna" : "Bob")
    }
    let mergedTimeline = SpeakingTimeline(intervals: [shown("Anna", 60, 68)])
    let mergedNames = SpeakerNaming.names(
      for: segments(merged), timeline: mergedTimeline,
      embeddings: embeddings(merged, voices: distinct))
    precondition(
      mergedNames == ["Anna", nil, "Anna", nil, "Anna", nil, "Anna", nil],
      "Another voice inside a named cluster stays anonymous")

    // A false 2 s Anna indicator during Bob, whose own voice Teams never shows.
    var falseAnchor = (0..<4).map {
      Turn(start: Double($0) * 20, end: Double($0) * 20 + 12, voice: "S1", person: "Anna")
    }
    falseAnchor.append(Turn(start: 90, end: 93, voice: "S2", person: "Bob"))
    falseAnchor += (0..<4).map {
      Turn(start: 100 + Double($0) * 20, end: 115 + Double($0) * 20, voice: "S2", person: "Bob")
    }
    let falseTimeline = SpeakingTimeline(
      intervals: falseAnchor.prefix(4).map { shown("Anna", $0.start, $0.end) } + [
        shown("Anna", 90.5, 92.5)
      ])
    let falseNames = SpeakerNaming.decisions(
      for: segments(falseAnchor), timeline: falseTimeline,
      embeddings: embeddings(falseAnchor, voices: distinct), participants: ["Anna", "Bob"])
    precondition(
      falseNames.map(\.name) == ["Anna", "Anna", "Anna", "Anna", "Anna", nil, nil, nil, nil],
      "A false anchor that does not sound like the participant cannot name a voice")
    var contaminated = falseAnchor
    for index in contaminated.indices where contaminated[index].person == "Anna" {
      contaminated[index].voice = "S2"
    }
    let contaminatedTimeline = SpeakingTimeline(intervals: [
      shown("Anna", 0, 12), shown("Anna", 20, 32), shown("Anna", 90.5, 92.5),
    ])
    precondition(
      SpeakerNaming.names(
        for: segments(contaminated), timeline: contaminatedTimeline,
        embeddings: embeddings(contaminated, voices: distinct), participants: ["Anna", "Bob"]
      ).prefix(5) == ["Anna", "Anna", nil, nil, "Anna"],
      "A voice with an anchor that sounds like someone else takes no names from sound")

    // Sam's voice is split; the second part has no Teams evidence at all.
    let split = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Sam"),
      Turn(start: 28, end: 40, voice: "S1", person: "Anna"),
      Turn(start: 42, end: 54, voice: "S2", person: "Sam"),
      Turn(start: 56, end: 68, voice: "S3", person: "Sam"),
      Turn(start: 70, end: 82, voice: "S3", person: "Sam"),
    ]
    let splitTimeline = SpeakingTimeline(
      intervals: split.prefix(4).map {
        shown($0.person, $0.start, $0.end)
      })
    let splitEmbeddings = embeddings(split, voices: distinct)
    let splitNames = SpeakerNaming.decisions(
      for: segments(split), timeline: splitTimeline, embeddings: splitEmbeddings,
      participants: ["Anna", "Sam"])
    precondition(
      splitNames.map(\.name) == ["Anna", "Sam", "Anna", "Sam", "Sam", "Sam"]
        && splitNames[4].reason == .voiceMatch,
      "A voice without Teams evidence takes the one participant it clearly sounds like")
    for participants in [nil, ["Anna", "Sam", "Bob"]] {
      precondition(
        SpeakerNaming.names(
          for: segments(split), timeline: splitTimeline, embeddings: splitEmbeddings,
          participants: participants
        ).suffix(2) == [nil, nil],
        "Without the full roster, or with a participant nobody heard, the voice stays anonymous")
    }
    precondition(
      SpeakerNaming.names(
        for: segments(split), timeline: .init(intervals: Array(splitTimeline.intervals.prefix(3))),
        embeddings: splitEmbeddings, participants: ["Anna", "Sam"]
      ).suffix(2) == [nil, nil], "A single anchor is too little to recognize a voice elsewhere")
    precondition(
      SpeakerNaming.names(
        for: segments(split),
        timeline: .init(intervals: splitTimeline.intervals + [shown("Anna", 70, 71.5)]),
        embeddings: splitEmbeddings, participants: ["Anna", "Sam"]
      ).suffix(2) == [nil, nil], "A voice Teams showed as someone else is not matched by sound")
    let similar = voices(["Anna", "Sam"], similarity: 0.75, seed: 5)
    precondition(
      SpeakerNaming.names(
        for: segments(split), timeline: splitTimeline,
        embeddings: embeddings(split, voices: similar), participants: ["Anna", "Sam"]
      ).suffix(2) == [nil, nil], "Voices too alike to tell apart are not matched")
    let simultaneous = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Sam"),
      Turn(start: 42, end: 54, voice: "S2", person: "Sam"),
      Turn(start: 44, end: 52, voice: "S3", person: "Sam"),
      Turn(start: 70, end: 82, voice: "S3", person: "Sam"),
      Turn(start: 84, end: 96, voice: "S2", person: "Sam"),
    ]
    let simultaneousTimeline = SpeakingTimeline(intervals: [
      shown("Anna", 0, 12), shown("Sam", 14, 26), shown("Sam", 84, 96),
    ])
    precondition(
      SpeakerNaming.names(
        for: segments(simultaneous), timeline: simultaneousTimeline,
        embeddings: embeddings(simultaneous, voices: distinct), participants: ["Anna", "Sam"])
        == ["Anna", "Sam", "Sam", nil, "Sam", "Sam"],
      "Speech during a participant's own named turn is someone else")

    // Teams keeps showing Anna while Bob, whom it showed twice before, speaks.
    let stuck = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Bob"),
      Turn(start: 28, end: 40, voice: "S1", person: "Anna"),
      Turn(start: 42, end: 54, voice: "S2", person: "Bob"),
      Turn(start: 70, end: 82, voice: "S2", person: "Bob"),
    ]
    func stuckTimeline(_ last: SpeakingTimeline.Interval) -> SpeakingTimeline {
      SpeakingTimeline(
        intervals: stuck.prefix(4).map { shown($0.person, $0.start, $0.end) } + [last])
    }
    let lingered = stuckTimeline(shown("Anna", 67.5, 82))
    let corrected = SpeakerNaming.decisions(
      for: segments(stuck), timeline: lingered, embeddings: embeddings(stuck, voices: distinct))
    precondition(
      SpeakerNaming.readingNames(for: segments(stuck), timeline: lingered)[4] == "Anna"
        && corrected[4].name == "Bob" && corrected[4].reason == .voiceCorrection
        && corrected[4].reading == "Anna" && corrected[4].candidate == "Bob"
        && corrected.prefix(4).map(\.name) == ["Anna", "Bob", "Anna", "Bob"],
      "A clearly contradicted reading takes the participant the voice matches")
    precondition(
      SpeakerNaming.names(
        for: segments(stuck), timeline: stuckTimeline(shown("Anna", 70.5, 82)),
        embeddings: embeddings(stuck, voices: distinct))[4] == "Bob",
      "A false indicator during another participant's voice is corrected too")
    func kept(_ turns: [Turn], _ timeline: SpeakingTimeline, _ voices: [String: [Double]])
      -> Bool
    {
      SpeakerNaming.names(
        for: segments(turns), timeline: timeline, embeddings: embeddings(turns, voices: voices)
      )[4] == "Anna"
    }
    precondition(
      kept(stuck, lingered, voices(people, similarity: 0.85, seed: 3)),
      "Voices too alike never overrule Teams")
    var short = stuck
    short[4].end = 75
    precondition(kept(short, lingered, distinct), "Short turns keep their reading")
    precondition(
      kept(
        stuck,
        SpeakingTimeline(intervals: lingered.intervals.filter { $0.start < 40 || $0.start > 60 }),
        distinct), "One reference for the other participant is not enough to overrule Teams")
    var stuckOverheard = embeddings(stuck, voices: distinct)
    stuckOverheard.append(
      .init(speaker: "S3", start: 71, end: 81, values: stuckOverheard[0].values))
    precondition(
      SpeakerNaming.names(for: segments(stuck), timeline: lingered, embeddings: stuckOverheard)[4]
        == "Anna", "A turn in which another voice was heard keeps its reading")
    // Handmade voices: anchors for Anna, Bob and Carl, then a turn Teams still shows as Anna.
    let three = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Bob"),
      Turn(start: 28, end: 40, voice: "S3", person: "Carl"),
      Turn(start: 42, end: 54, voice: "S1", person: "Anna"),
      Turn(start: 56, end: 68, voice: "S2", person: "Bob"),
      Turn(start: 84, end: 96, voice: "S3", person: "Carl"),
      Turn(start: 110, end: 122, voice: "S4", person: "?"),
    ]
    let threeTimeline = SpeakingTimeline(
      intervals: three.prefix(6).map { shown($0.person, $0.start, $0.end) } + [
        shown("Anna", 107.5, 122)
      ])
    let basis: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
    func checked(_ voice: [Float]) -> String? {
      var pieces = three.prefix(6).enumerated().map { index, turn in
        TranscriptSegments.VoiceEmbedding(
          speaker: turn.voice, start: turn.start, end: turn.end,
          values: vector(basis[index % 3].enumerated().map { $0.element + 0.01 * Float($0.offset) })
        )
      }
      pieces += [(110.0, 122.0), (112.0, 122.0)].map {
        .init(speaker: "S4", start: $0.0, end: $0.1, values: vector(voice))
      }
      return SpeakerNaming.names(
        for: segments(three), timeline: threeTimeline, embeddings: pieces)[6]
    }
    precondition(checked([0.01, 1, 0, 0.01]) == "Bob", "A clear voice match corrects the reading")
    precondition(
      checked([0, 0.81, 0.58, 0.08]) == "Anna",
      "A voice between two other participants does not overrule Teams")
    precondition(
      checked([0.52, 0.82, 0, 0]) == "Anna",
      "A voice that also resembles the shown participant does not overrule Teams")
    // Overlapping windows repeat the same speech; they must not add up to more evidence.
    func overlapped(_ windows: [(Double, Double, [Float])]) -> SpeakerFusion.Decision {
      var pieces = three.prefix(6).enumerated().map { index, turn in
        TranscriptSegments.VoiceEmbedding(
          speaker: turn.voice, start: turn.start, end: turn.end,
          values: vector(basis[index % 3].enumerated().map { $0.element + 0.01 * Float($0.offset) })
        )
      }
      pieces += windows.map {
        .init(speaker: "S4", start: $0.0, end: $0.1, values: vector($0.2))
      }
      return SpeakerNaming.decisions(
        for: segments(three), timeline: threeTimeline, embeddings: pieces)[6]
    }
    let repeated = overlapped(
      [0, 0.2, 0.1, 0.3, 0.05].map { (110 + $0, 113.4 + $0, [0.01, 1, 0, 0.01]) })
    precondition(
      repeated.name == "Anna" && repeated.rejection?.contains("own speech") == true
        && repeated.candidate == "Bob",
      "Shifted windows over one short passage are not enough to overrule Teams: \(repeated)")
    let weighted = overlapped(
      [0, 0.025, 0.05, 0.075, 0.1].map { (110 + $0, 113 + $0, [0, 0.9, 0.436, 0]) } + [
        (113.1, 122, [0, 0.74, 0, 0.672])
      ])
    precondition(
      weighted.name == "Anna" && weighted.rejection?.contains("average similarity") == true,
      "Repeated windows do not outweigh the rest of the turn: \(weighted)")
    let overlapping: [(Double, Double, String, [Float])] = [
      (0, 12, "S1", [1, 0, 0]), (28, 40, "S1", [1, 0.02, 0]), (14, 26, "S2", [0, 1, 0]),
      (42, 76, "S2", [0, 1, 0.02]), (72, 82, "S2", [0, 1, 0.01]), (74, 82, "S2", [0.01, 1, 0]),
    ]
    precondition(
      SpeakerNaming.names(
        for: segments(stuck), timeline: lingered,
        embeddings: overlapping.map {
          .init(speaker: $0.2, start: $0.0, end: $0.1, values: vector($0.3))
        })[4] == "Anna",
      "A reference that includes the checked turn's own audio cannot overrule Teams")

    func handmadeEmbeddings(_ pieces: [(Double, Double, String, [Float])])
      -> [TranscriptSegments.VoiceEmbedding]
    {
      pieces.map { .init(speaker: $0.2, start: $0.0, end: $0.1, values: vector($0.3)) }
    }
    let annaAndSam: [(Double, Double, String, [Float])] = [
      (0, 12, "S1", [1, 0, 0]), (14, 26, "S2", [0, 1, 0]), (28, 40, "S1", [1, 0.02, 0]),
      (42, 54, "S2", [0.02, 1, 0]),
    ]
    let annaAndSamTurns = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 26, voice: "S2", person: "Sam"),
      Turn(start: 28, end: 40, voice: "S1", person: "Anna"),
      Turn(start: 42, end: 54, voice: "S2", person: "Sam"),
    ]
    let annaAndSamShown = annaAndSamTurns.map { shown($0.person, $0.start, $0.end) }

    // Bob sounds like Anna and shares her diarizer voice; Teams shows him once, with an
    // indicator that switched on before his turn.
    let sharedVoice =
      annaAndSamTurns + [
        Turn(start: 56, end: 60, voice: "S1", person: "Bob"),
        Turn(start: 70, end: 130, voice: "S1", person: "Bob"),
        Turn(start: 140, end: 170, voice: "S1", person: "Bob"),
      ]
    let sharedNames = SpeakerNaming.decisions(
      for: segments(sharedVoice),
      timeline: .init(intervals: annaAndSamShown + [shown("Bob", 53, 60)]),
      embeddings: handmadeEmbeddings(
        annaAndSam + [
          (56, 60, "S1", [0.8, 0, 0.6]), (70, 130, "S1", [0.8, 0, 0.6]),
          (140, 170, "S1", [0.8, 0.01, 0.6]),
        ]))
    precondition(
      sharedNames[4].name == "Bob" && !sharedNames[4].anchor
        && sharedNames.suffix(2).allSatisfy {
          $0.name == nil && $0.rejection == "the voice shows several participants"
        },
      "A voice whose readings also name someone else takes no name from sound: \(sharedNames)")

    // Anna's voice is split into a voice Teams never showed, and a short remark of Sam was
    // misclustered into it without an embedding of its own.
    let splitWithRemark =
      annaAndSamTurns + [
        Turn(start: 70, end: 82, voice: "S3", person: "Anna"),
        Turn(start: 90, end: 102, voice: "S3", person: "Anna"),
        Turn(start: 110, end: 111.5, voice: "S3", person: "Sam"),
      ]
    let remarkNames = SpeakerNaming.decisions(
      for: segments(splitWithRemark), timeline: .init(intervals: annaAndSamShown),
      embeddings: handmadeEmbeddings(
        annaAndSam + [(70, 82, "S3", [1, 0.01, 0]), (90, 102, "S3", [1, 0, 0.01])]),
      participants: ["Anna", "Sam"])
    precondition(
      remarkNames.suffix(3).map(\.name) == ["Anna", "Anna", nil]
        && remarkNames[6].rejection == "no voice embedding of its own",
      "A recognized voice names only turns with an embedding of their own: \(remarkNames)")

    // A few seconds of a voice Teams never showed, such as a shared video, resemble Sam.
    let brief =
      annaAndSamTurns + [Turn(start: 56, end: 60, voice: "S3", person: "video")]
    let briefName = SpeakerNaming.decisions(
      for: segments(brief), timeline: .init(intervals: annaAndSamShown),
      embeddings: handmadeEmbeddings(annaAndSam + [(56, 60, "S3", [0.3, 0.95, 0.1])]),
      participants: ["Anna", "Sam"])[4]
    precondition(
      briefName.name == nil && briefName.rejection == "too little speech in the voice",
      "A few seconds of an unknown voice are too little to recognize: \(briefName)")

    // Teams shows Anna for most of a turn of Bob, then Bob, and never again.
    let switched = [
      Turn(start: 0, end: 8, voice: "S2", person: "Bob"),
      Turn(start: 20, end: 40, voice: "S2", person: "Bob"),
      Turn(start: 50, end: 70, voice: "S2", person: "Bob"),
    ]
    let switchedNames = SpeakerNaming.decisions(
      for: segments(switched),
      timeline: .init(intervals: [shown("Anna", 0, 6), shown("Bob", 6.7, 8)]),
      embeddings: handmadeEmbeddings([
        (0, 8, "S2", [0, 0, 1]), (20, 40, "S2", [0, 0.02, 1]), (50, 70, "S2", [0.01, 0, 1]),
      ]))
    precondition(
      switchedNames.map(\.name) == ["Anna", nil, nil] && !switchedNames[0].anchor,
      "A turn Teams also shows someone else for is no anchor: \(switchedNames)")

    // Anna's indicator switches on with a turn of Bob's voice and Bob's soon after; the
    // readings give the turn to Bob.
    let crosstalk = [
      Turn(start: 0, end: 8, voice: "S2", person: "Bob"),
      Turn(start: 20, end: 32, voice: "S2", person: "Bob"),
      Turn(start: 40, end: 52, voice: "S2", person: "Bob"),
    ]
    let crosstalkNames = SpeakerNaming.decisions(
      for: segments(crosstalk),
      timeline: .init(intervals: [
        shown("Anna", 0, 7.3), shown("Bob", 4.2, 8), shown("Bob", 20, 32), shown("Bob", 40, 52),
      ]),
      embeddings: handmadeEmbeddings([
        (0, 8, "S2", [0, 0, 1]), (20, 32, "S2", [0, 0.02, 1]), (40, 52, "S2", [0.01, 0, 1]),
      ]))
    precondition(
      crosstalkNames[0].name == "Bob" && !crosstalkNames[0].anchor,
      "A turn read as someone else is no anchor: \(crosstalkNames)")

    // A short, noisy embedding at the end of a long turn in Anna's voice.
    let tail = annaAndSamTurns + [Turn(start: 60, end: 160, voice: "S1", person: "Anna")]
    let tailName = SpeakerNaming.decisions(
      for: segments(tail), timeline: .init(intervals: annaAndSamShown),
      embeddings: handmadeEmbeddings(
        annaAndSam + [(60, 150, "S1", [1, 0, 0.05]), (150, 153.5, "S1", [0.47, 0, 0.88])]))[4]
    precondition(
      tailName.name == "Anna" && tailName.reason == .voiceOfNamedCluster,
      "Short embeddings need only a lower similarity: \(tailName)")

    // Sam's indicator lingers three seconds into Anna's turn while hers is on.
    let lingeringOverlap = SpeakerNaming.decisions(
      for: segments(annaAndSamTurns),
      timeline: .init(intervals: [
        shown("Anna", 0, 12), shown("Sam", 14, 31), shown("Anna", 28, 40), shown("Sam", 42, 54),
      ]),
      embeddings: handmadeEmbeddings(annaAndSam))
    precondition(
      lingeringOverlap[2].name == "Anna" && lingeringOverlap[2].anchor,
      "Time two indicators share counts for neither: \(lingeringOverlap)")

    // Bob speaks into Anna's laptop in her room; Teams shows Anna three times for him and twice
    // for her, and Bob has no account.
    let sameRoom = [
      Turn(start: 0, end: 12, voice: "S1", person: "Anna"),
      Turn(start: 14, end: 22, voice: "S2", person: "Bob"),
      Turn(start: 28, end: 40, voice: "S1", person: "Anna"),
      Turn(start: 42, end: 50, voice: "S2", person: "Bob"),
      Turn(start: 56, end: 64, voice: "S2", person: "Bob"),
      Turn(start: 100, end: 160, voice: "S2", person: "Bob"),
      Turn(start: 170, end: 200, voice: "S2", person: "Bob"),
    ]
    let sameRoomNames = SpeakerNaming.decisions(
      for: segments(sameRoom),
      timeline: .init(intervals: sameRoom.prefix(5).map { shown("Anna", $0.start, $0.end) }),
      embeddings: handmadeEmbeddings([
        (0, 12, "S1", [1, 0, 0]), (14, 22, "S2", [0, 0, 1]), (28, 40, "S1", [1, 0.02, 0]),
        (42, 50, "S2", [0.01, 0, 1]), (56, 64, "S2", [0, 0.01, 1]),
        (100, 160, "S2", [0, 0.02, 1]), (170, 200, "S2", [0.02, 0, 1]),
      ]))
    precondition(
      sameRoomNames.suffix(2).allSatisfy { $0.name == nil },
      "A participant whose anchors sound like two people has no reference: \(sameRoomNames)")

    var invalid = embeddings(sparse, voices: distinct)
    for index in invalid.indices {
      invalid[index].values = index % 2 == 0 ? [.nan] + invalid[index].values.dropFirst() : []
    }
    precondition(
      SpeakerNaming.names(for: segments(sparse), timeline: sparseTimeline, embeddings: invalid)
        == [nil, "Sam", nil, "Anna", "Sam"], "Malformed embeddings are ignored")
    var otherSources = segments(sparse)
    otherSources[0].source = .deviceAudio
    otherSources[2].source = .microphone
    precondition(
      SpeakerNaming.names(
        for: otherSources, timeline: sparseTimeline,
        embeddings: embeddings(sparse, voices: distinct)) == [nil, "Sam", nil, "Anna", "Sam"],
      "Teams identities never reach other audio sources")
    precondition(
      SpeakerNaming.names(
        for: segments(sparse), timeline: sparseTimeline, excluded: ["Anna"],
        embeddings: embeddings(sparse, voices: distinct)) == [nil, "Sam", nil, nil, "Sam"],
      "The local identity never names remote voices")
    precondition(
      SpeakerNaming.names(
        for: segments(sparse), timeline: .init(),
        embeddings: embeddings(sparse, voices: distinct)
      ).allSatisfy { $0 == nil },
      "Voice evidence cannot invent names without Teams evidence")

    let result = TranscriptSegments(
      mode: .separateTracks, duration: 72, segments: segments(sparse),
      voiceEmbeddings: embeddings(sparse, voices: distinct), engine: "fixture")
    let decoded = try JSONDecoder().decode(
      TranscriptSegments.self, from: JSONEncoder().encode(result))
    precondition(decoded == result, "Helper IPC preserves embeddings and timing")
    print("Speaker fusion: sparse, lingering, merged, false, split and similar voices: OK")
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

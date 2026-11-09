import Foundation

/// Which audio whisper hears and how its words are attributed to speakers.
enum SpeechPlanSmoke {
  typealias Plan = SpeechPlan

  static func run() {
    testRepairedTurns()
    testPassages()
    testLanguages()
    testUnidentifiedSpeech()
    testChunks()
    testPlacement()
    testAttribution()
    print("Speech passages, chunks per language, word placement and attribution: OK")
  }

  private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

  private static func testRepairedTurns() {
    func turn(_ start: Double, _ end: Double, _ speaker: String) -> Plan.Turn {
      Plan.Turn(start: start, end: end, speaker: speaker)
    }
    let repaired = Plan.repairedTurns(
      [
        turn(70.3, 74.0068, "S3"), turn(74.0068, 75.47, "S2"), turn(76, 82, "S2"),
        turn(90, 98, "S1"), turn(98.6, 99.5, "S4"), turn(99.5, 105, "S1"),
        turn(110.8, 112, "S3"), turn(112, 118, "S1"),
      ], windowStep: 2)
    precondition(
      repaired.map(\.speaker) == ["S3", "S3", "S2", "S1", "S4", "S1", "S1", "S1"],
      "Short turns split off on a window edge join their neighbor: \(repaired.map(\.speaker))")
  }

  private static func testPassages() {
    let turns = [
      Plan.Turn(start: 0.5, end: 4, speaker: "A"),
      Plan.Turn(start: 6.4, end: 9, speaker: "B"),
      Plan.Turn(start: 20, end: 24, speaker: "A"),
    ]
    let regions = [
      Plan.Region(start: 0.3, end: 2), Plan.Region(start: 2.1, end: 4),
      Plan.Region(start: 5.4, end: 9), Plan.Region(start: 20, end: 24),
    ]
    let passages = Plan.passages(
      regions: regions, turns: turns, policy: .speakers, trackDuration: 30)
    precondition(passages.map(\.speaker) == ["A", "B", "A"], "\(passages)")
    precondition(
      close(passages[0].start, 0.1) && close(passages[0].end, 4.2),
      "A very short pause stays inside a passage: \(passages[0])")
    precondition(
      close(passages[1].start, 5.2),
      "Speech before a turn the diarizer starts late belongs to that turn: \(passages[1])")

    let echo = Plan.passages(
      regions: [Plan.Region(start: 1, end: 3), Plan.Region(start: 10, end: 12)],
      turns: [Plan.Turn(start: 10.4, end: 12, speaker: "local")], policy: .localSpeech,
      trackDuration: 20)
    precondition(
      echo.count == 1 && close(echo[0].start, 9.8),
      "Microphone speech far from local turns is playback and is not transcribed")
    precondition(
      Plan.passages(regions: regions, turns: [], policy: .localSpeech, trackDuration: 30).isEmpty)

    let handover = Plan.passages(
      regions: [Plan.Region(start: 30, end: 40)],
      turns: [
        Plan.Turn(start: 29.8, end: 34, speaker: "A"),
        Plan.Turn(start: 33.5, end: 34.2, speaker: "C"),
        Plan.Turn(start: 34.3, end: 37, speaker: "B"),
        Plan.Turn(start: 36.6, end: 40, speaker: "A"),
      ], policy: .speakers, trackDuration: 50)
    precondition(
      handover.map(\.speaker) == ["A", "B", "A"] && close(handover[1].start, 34.15)
        && close(handover[2].start, 36.6),
      "Speakers taking over without a pause get their own passages: \(handover)")
    precondition(
      Plan.split(
        [Plan.Region(start: 0, end: 3)],
        at: [
          Plan.Turn(start: 0, end: 2.5, speaker: "A"),
          Plan.Turn(start: 2.5, end: 3.2, speaker: "B"),
        ]
      ).count == 1, "A region is not cut closer than the split minimum to its end")
  }

  private static func testLanguages() {
    func passage(_ start: Double, _ end: Double, _ speaker: String) -> Plan.Passage {
      Plan.Passage(start: start, end: end, speaker: speaker)
    }
    func heard(_ language: String, _ probability: Double) -> Plan.Detection {
      Plan.Detection(language: language, probability: probability)
    }
    let languages = Plan.languages(
      passages: [
        passage(0, 10, "A"), passage(10, 14, "A"), passage(14, 15, "A"), passage(15, 20, "B"),
        passage(20, 25, "B"), passage(25, 28, "B"), passage(28, 29, "B"), passage(30, 32, "A"),
      ],
      detections: [
        heard("de", 1), heard("en", 0.6), nil, heard("en", 0.95), heard("de", 0.99),
        heard("fr", 0.6), nil, heard("en", 0.97),
      ])
    precondition(
      languages == ["de", "de", "de", "en", "de", "fr", nil, "en"],
      "Unsure and short passages take the language their speaker sticks to: \(languages)")
  }

  private static func testUnidentifiedSpeech() {
    let regions = [Plan.Region(start: 1, end: 2.5)]
    let turns = Plan.unidentifiedTurns(in: regions)
    let passages = Plan.passages(
      regions: regions, turns: turns, policy: .speakers, trackDuration: 4)
    let chunks = Plan.chunks(passages: passages, languages: [nil])
    precondition(chunks.count == 1, "Speech without a speaker cluster must reach recognition")
    let words = chunks[0].place([Plan.Word(start: 0.3, end: 0.8, text: "Hallo.")])
    let segments = Plan.segments(words: words, turns: turns, policy: .speakers)
    precondition(segments.count == 1 && segments[0].text == "Hallo.")
    precondition(segments[0].speaker == "unidentified")
    let silent = Plan.passages(
      regions: [], turns: Plan.unidentifiedTurns(in: []), policy: .speakers, trackDuration: 4)
    precondition(Plan.chunks(passages: silent, languages: []).isEmpty)
  }

  private static func testChunks() {
    func passage(_ start: Double, _ end: Double, _ speaker: String) -> Plan.Passage {
      Plan.Passage(start: start, end: end, speaker: speaker)
    }
    let passages = [
      passage(0, 5, "A"), passage(5.5, 9, "B"), passage(9.4, 10, "A"), passage(20, 26, "A"),
      passage(27, 30, "C"),
    ]
    let chunks = Plan.chunks(passages: passages, languages: ["de", "de", nil, "de", "fr"])
    precondition(chunks.count == 2, "A new language starts a new chunk: \(chunks)")
    precondition(chunks[0].language == "de" && chunks[1].language == "fr")
    precondition(
      zip(chunks[0].pieces.map(\.offset), [0, 5.5, 9.4, 11]).allSatisfy { close($0, $1) },
      "Short pauses stay as recorded, long ones become the joined silence: \(chunks[0].pieces)")
    precondition(close(chunks[0].duration, 17))

    let long = (0..<6).map { passage(Double($0) * 10, Double($0) * 10 + 8, "A") }
    let packed = Plan.chunks(passages: long, languages: Array(repeating: "en", count: 6))
    precondition(packed.count == 2, "Chunks stay below the maximum: \(packed.map(\.duration))")
    precondition(packed.allSatisfy { $0.duration <= Plan.maximumChunkSeconds })

    let unknown = Plan.chunks(passages: [passage(0, 1, "A")], languages: [nil])
    precondition(unknown.count == 1 && unknown[0].language == nil)
  }

  private static func testPlacement() {
    let chunk = Plan.Chunk(
      language: "de",
      pieces: [
        Plan.Piece(passage: Plan.Passage(start: 10, end: 12, speaker: "A"), offset: 0),
        Plan.Piece(passage: Plan.Passage(start: 30, end: 31, speaker: "B"), offset: 3),
      ])
    precondition(close(chunk.duration, 4))
    precondition(chunk.pieceIndex(at: 2.4) == 0 && chunk.pieceIndex(at: 2.6) == 1)
    let placed = chunk.place([
      Plan.Word(start: 0.5, end: 1, text: " eins"),
      Plan.Word(start: 1.9, end: 2.7, text: " zwei"),
      Plan.Word(start: 2.6, end: 2.9, text: " drei"),
      Plan.Word(start: 2.2, end: 2.4, text: " vier"),
      Plan.Word(start: 3.5, end: 5, text: " fünf"),
    ])
    precondition(placed.map(\.speaker) == ["A", "A", "B", "B", "B"], "\(placed)")
    precondition(close(placed[0].word.start, 10.5) && close(placed[0].word.end, 11))
    precondition(
      close(placed[1].word.end, 12), "A word reaching into the join ends with its passage")
    precondition(close(placed[2].word.start, 30), "Early word times snap into the next passage")
    precondition(
      close(placed[3].word.start, 30), "A word never lands before the previous word's passage")
    precondition(close(placed[4].word.end, 31))
  }

  private static func testAttribution() {
    func word(_ start: Double, _ text: String, _ speaker: String) -> (
      word: Plan.Word, speaker: String
    ) {
      (Plan.Word(start: start, end: start + 0.25, text: text), speaker)
    }
    let turns = [
      Plan.Turn(start: 0, end: 4.5, speaker: "A"),
      Plan.Turn(start: 3.75, end: 7, speaker: "B"),
    ]
    let segments = Plan.segments(
      words: [
        word(0.25, " Das", "A"), word(1, " passt", "A"), word(1.5, " gut.", "A"),
        word(3.25, " Hallo,", "A"), word(3.75, " mache", "A"), word(4, " ich.", "A"),
      ], turns: turns, policy: .speakers)
    precondition(
      segments == [
        Plan.Segment(start: 0.25, end: 1.75, speaker: "A", text: "Das passt gut."),
        Plan.Segment(start: 3.25, end: 4.25, speaker: "B", text: "Hallo, mache ich."),
      ], "Overlapping speech inside another speaker's new turn goes to them: \(segments)")

    let short = Plan.segments(
      words: [word(1, " Ja", "A"), word(4.5, " genau", "A")], turns: turns, policy: .speakers)
    precondition(short.count == 2 && short.allSatisfy { $0.speaker == "A" })
    precondition(
      Plan.segments(
        words: [word(1, " eins", "A"), word(4.5, " zwei", "A")], turns: [], policy: .speakers
      )
      .count == 2, "Words far apart start a new segment")

    let local = [Plan.Turn(start: 2, end: 4, speaker: "local")]
    let mic = Plan.segments(
      words: [
        word(0, " echo", "local"), word(1.6, " Ja,", "local"), word(2.5, " genau.", "local"),
        word(6, " echo", "local"),
      ], turns: local, policy: .localSpeech)
    precondition(
      mic == [Plan.Segment(start: 1.6, end: 2.75, speaker: "local", text: "Ja, genau.")],
      "Microphone words far from local speech are dropped: \(mic)")
    let instant = Plan.segments(
      words: [(Plan.Word(start: 2.5, end: 2.5, text: " Okay."), "local")], turns: local,
      policy: .localSpeech)
    precondition(instant.map(\.text) == ["Okay."], "Words without duration are kept")
    let dashed = Plan.segments(
      words: [
        word(0.25, " Got", "A"), word(0.5, " it.", "A"), word(1, " -", "A"),
        word(1.25, " That", "A"), word(1.5, " works.", "A"),
      ], turns: [], policy: .speakers)
    precondition(
      dashed.map(\.text) == ["Got it. That works."], "whisper's speaker dash is dropped: \(dashed)")
  }
}

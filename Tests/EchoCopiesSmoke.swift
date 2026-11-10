import Foundation

/// Loudspeaker echo that the level filter kept, modeled on a laptop meeting without headphones:
/// the microphone repeats remote speech with recognition differences and shifted word times,
/// while the local participant also talks over remote speakers.
enum EchoCopiesSmoke {
  private typealias Placed = (word: SpeechPlan.Word, speaker: String)

  private static func words(_ text: String, _ start: Double, _ end: Double) -> [SpeechPlan.Word] {
    let parts = text.split(separator: " ").map(String.init)
    let step = (end - start) / Double(parts.count)
    return parts.enumerated().map { index, part in
      SpeechPlan.Word(
        start: start + Double(index) * step, end: start + Double(index + 1) * step,
        text: " " + part)
    }
  }

  /// What the microphone recognizes of remote words `range`: shifted, some words heard
  /// differently, and extra words recognized from the room.
  private static func echo(
    _ remote: [SpeechPlan.Word], _ range: ClosedRange<Int>, shift: Double = 0.25,
    heard: [Int: String] = [:], prefix: String? = nil
  ) -> [Placed] {
    var result = range.map { index -> Placed in
      var word = remote[index]
      word.start += shift
      word.end += shift
      if let text = heard[index] { word.text = " " + text }
      return (word, "local")
    }
    if let prefix, let first = result.first {
      result.insert(
        (
          SpeechPlan.Word(start: first.word.start - 0.4, end: first.word.start, text: " " + prefix),
          "local"
        ), at: 0)
    }
    return result
  }

  /// Teams plays sound while a remote word is said, as the echo filter measures it.
  private static func playing(_ remote: [SpeechPlan.Word]) -> (SpeechPlan.Word) -> Bool {
    { word in
      let start = word.start - 0.2
      let end = word.end + 0.2
      let covered = remote.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
      return covered >= 0.3 * (end - start)
    }
  }

  static func run() {
    let remote =
      words("Na,", 0.3, 1.0)
      + words("schon wieder die Unterlagen gesucht,", 6.1, 8.5)
      + words("festgehangen.", 16.9, 17.4)
      + words(
        "Ich bin immer weiter nach unten gegangen, aber das hängt ganz oben, das Log.", 20.3, 30.6)
      + words("Wir haben nur eine halbe Stunde und ich hatte gerade gesagt.", 55.4, 61.3)
      + words("eine fleißige Hand im Projektoffice sozusagen.", 130.0, 137.0)
      + words("Donnerstag geht es ins Quality Gate.", 140.0, 143.0)
      + words("Wir sollten die Zahlen bis Freitag prüfen und dann entscheiden.", 150.0, 156.0)
      + words("Ich bin gleich wieder da.", 158.0, 159.5)
      + words("Ja, das passt.", 160.0, 161.5)
    func index(_ text: String, after start: Double) -> Int {
      remote.firstIndex { $0.start >= start && EchoCopies.token($0.text) == text }!
    }
    let ich = index("ich", after: 20)
    let halbe = index("halbe", after: 55)
    let sozusagen = index("sozusagen", after: 130)
    let donnerstag = index("donnerstag", after: 139)
    var local: [[Placed]] = [
      [(SpeechPlan.Word(start: 0.6, end: 1.0, text: " Na?"), "local")]
        + words("Nein.", 1.6, 2.2).map { ($0, "local") },
      echo(remote, index("schon", after: 6)...index("gesucht", after: 6)),
      echo(remote, index("festgehangen", after: 16)...index("festgehangen", after: 16))
        + echo(remote, ich...ich + 1, shift: -3.1),
      echo(remote, ich + 2...ich + 13, shift: 0.3, heard: [ich + 13: "Look."]),
      echo(remote, halbe...halbe + 6),
      echo(remote, sozusagen...sozusagen),
      echo(remote, donnerstag...donnerstag + 5, prefix: "Mhm"),
    ]
    let real: [(String, Double, Double)] = [
      ("Können wir den Termin auf nächste Woche verschieben?", 150.5, 154.0),
      ("Ja, genau.", 160.2, 161.0),
      ("Das Projektoffice übernimmt die Planung.", 131.0, 133.5),
      ("Donnerstag geht es ins Quality Gate.", 145.5, 148.5),
      ("Ich bin dabei.", 157.5, 158.6),
    ]
    local += real.map { text, start, end in words(text, start, end).map { ($0, "local") } }
    let result = EchoCopies.removing(
      from: local, heard: remote, coupling: 0.49, playing: playing(remote))
    let kept = result.chunks.map { $0.map(\.word.text).joined() }
    precondition(
      kept == [" Na? Nein.", "", " festgehangen. Ich bin", " Look.", "", " sozusagen.", " Mhm"]
        + real.map { " " + $0.0 },
      "Echo copies disappear and local speech stays, also a filler unlike the playback; a short "
        + "word misheard by two letters stays like a short word someone said: \(kept)")
    precondition(
      EchoCopies.removing(
        from: local, heard: remote, coupling: 0, playing: playing(remote)
      ).chunks.map { $0.map(\.word) } == local.map { $0.map(\.word) },
      "Without measured echo the microphone is unchanged")
    precondition(
      EchoCopies.removing(from: local, heard: remote, coupling: 0.49, playing: { _ in false })
        .removed == 0, "Words spoken while Teams played nothing are never echo")

    // Someone agrees, repeats or contradicts with nearly the same words.
    func reply(_ remoteText: String, _ localText: String, after delay: Double, length: Double = 1.2)
      -> String
    {
      let heard = words(remoteText, 10, 11.2)
      let said = [words(localText, 10 + delay, 10 + delay + length).map { ($0, "local") }]
      return EchoCopies.removing(
        from: said, heard: heard, coupling: 0.49, playing: playing(heard)
      ).chunks[0].map(\.word.text).joined()
    }
    // Agreement in the same word, even while the remote word still plays, is never removed;
    // answers after the remote sentence come while Teams plays nothing.
    for (remoteText, localText, delay) in [
      ("Genau.", "Genau.", 0.35), ("Genau.", "Genau.", 0.1),
      ("Ja das passt.", "Ja das passt.", 1.0),
      ("Wir brauchen keine Freigabe.", "Nein wir brauchen eine Freigabe.", 1.55),
      ("Wir brauchen keine Freigabe.", "Nein wir brauchen eine Freigabe.", 1.4),
      ("Dann machen wir das am Freitag.", "Dann machen wir das am Freitag.", 1.0),
      ("Dann machen wir das am Freitag.", "Ja dann machen wir das am Freitag.", 1.6),
    ] {
      precondition(
        reply(remoteText, localText, after: delay) == " " + localText,
        "A reply in nearly the same words stays: \(localText) after \(delay) s")
    }
    // Greetings and farewells said together with the remote speaker.
    for (remoteText, localText, delay) in [
      ("Good morning everyone.", "Good morning!", 0.0), ("Okay, thanks, bye!", "Thanks, bye!", 0.4),
      ("Okay, thanks, bye!", "Okay, thanks, bye!", 0.1),
    ] {
      precondition(
        reply(remoteText, localText, after: delay, length: 0.8) == " " + localText,
        "A short utterance said together with the speaker stays: \(localText)")
    }
    // Someone speaks up while the loudspeaker plays a remote sentence, which the microphone
    // recognizes too.
    let statement = words("We should ship the new release on Friday after the review.", 100, 104)
    let echoed = statement.map { word -> SpeechPlan.Word in
      var word = word
      word.start += 0.2
      word.end += 0.2
      return word
    }
    for interjection in ["Wait, no!", "No!", "Nein!", "Stop!"] {
      let interrupted = [
        (echoed + words(interjection, 102.05, 102.15)).sorted { $0.start < $1.start }.map {
          ($0, "local")
        }
      ]
      precondition(
        EchoCopies.removing(
          from: interrupted, heard: statement, coupling: 0.49, playing: playing(statement)
        ).chunks[0].map(\.word.text).joined() == " " + interjection,
        "Words unlike the playback stay inside its echo: \(interjection)")
    }
    // The interjection delays the words recognized after it.
    var delayed = echoed
    let boundary = delayed[5].end
    for index in 6..<delayed.count {
      delayed[index].start += 0.3
      delayed[index].end += 0.3
    }
    delayed.insert(.init(start: boundary, end: boundary + 0.3, text: " Nein!"), at: 6)
    precondition(
      EchoCopies.removing(
        from: [delayed.map { ($0, "local") }], heard: statement, coupling: 0.49,
        playing: playing(statement)
      ).chunks[0].contains { $0.word.text == " Nein!" },
      "A one-word interjection between echo words stays")
    print("Echo copies: repeated Teams speech removed, double talk and headsets unchanged: OK")
  }
}

import Foundation

enum VoiceProfilesSmoke {
  private static func axis(_ index: Int) -> [Double] {
    (0..<8).map { $0 == index ? 1 : 0 }
  }

  /// A unit vector whose cosine with `base` is `similarity`.
  private static func voice(_ base: [Double], _ similarity: Double, toward other: [Double])
    -> [Float]
  {
    zip(base, other).map {
      Float($0 * similarity + $1 * (1 - similarity * similarity).squareRoot())
    }
  }

  /// A separate-tracks result in which each voice speaks `seconds` in turn, with one embedding
  /// per ten seconds of its speech.
  private static func recording(_ voices: [(speaker: String, vector: [Float], seconds: Double)])
    -> TranscriptSegments
  {
    var segments: [TranscriptSegments.Segment] = [
      .init(start: 0, end: 1, source: .microphone, speaker: "local", text: "Hello.")
    ]
    var embeddings: [TranscriptSegments.VoiceEmbedding] = []
    var time = 1.0
    for voice in voices {
      var left = voice.seconds
      while left > 0 {
        let length = min(10, left)
        segments.append(
          .init(
            start: time, end: time + length, source: .teams, speaker: voice.speaker, text: "Talk."))
        embeddings.append(
          .init(speaker: voice.speaker, start: time, end: time + length, values: voice.vector))
        time += length
        left -= length
      }
    }
    var result = TranscriptSegments(
      mode: .separateTracks, duration: time, segments: segments, engine: "fixture engine")
    result.voiceEmbeddings = embeddings
    return result
  }

  private static func roster(_ remote: [String], full: Bool = false) -> ParticipantRoster {
    var roster = ParticipantRoster()
    roster.observe(
      [TeamsParticipantSighting(name: "Jona Bihl", isLocal: true, source: .tile)]
        + remote.map {
          TeamsParticipantSighting(
            name: $0, role: full ? "Attendee" : nil, source: full ? .roster : .tile)
        }, at: 0)
    return roster
  }

  static func run(_ directory: URL) throws {
    let anna = axis(0)
    let sam = axis(1)
    let date = Date(timeIntervalSince1970: 0)
    var profiles = VoiceProfiles()
    func known(
      _ result: TranscriptSegments, _ roster: ParticipantRoster?,
      naming: [SpeakerFusion.Decision]? = nil, in voices: inout VoiceProfiles
    ) -> (names: [String?], learned: Bool) {
      let outcome = TranscriptDocument.knownVoices(
        result, localName: "Jona", roster: roster, naming: naming, voices: &voices, at: date)
      return (outcome.names, outcome.learned)
    }

    let call = recording([("S1", voice(anna, 1, toward: sam), 20)])
    let first = known(call, roster(["Anna Schmidt"]), in: &profiles)
    precondition(
      first.learned && first.names.allSatisfy { $0 == nil }
        && profiles.profiles.map(\.name) == ["Anna Schmidt"],
      "A 1:1 call teaches the other person's voice: \(profiles.profiles.map(\.name))")

    let meeting = recording([
      ("S1", voice(anna, 0.9, toward: axis(2)), 20), ("S2", voice(axis(3), 1, toward: sam), 20),
    ])
    let tiles = roster(["Lena Hoffmann", "Marco Rossi"])
    var later = profiles
    let second = known(meeting, tiles, in: &later)
    precondition(
      second.names == [nil, "Anna Schmidt", "Anna Schmidt", nil, nil] && !second.learned
        && later == profiles,
      "A voice nothing names takes the name it had before and teaches nothing: \(second)")
    var record = MeetingRecord(id: "19700101T000000Z", startedAt: date, status: .transcribing)
    let text = TranscriptDocument.compose(
      meeting, into: &record, localName: "Jona", roster: tiles, naming: nil,
      knownVoices: second.names, timeZone: TimeZone(identifier: "UTC")!)
    precondition(
      record.speakers.map(\.label) == ["Jona", "Anna Schmidt", "Speaker 1"]
        && record.speakers[1].identity == .knownVoice && record.speakers[1].turns == 2
        && text.contains("- Anna Schmidt: a voice recognized from earlier meetings\n")
        && text.contains("[00:00:01] Anna Schmidt: Talk."),
      "Only the recognized voice takes a name: \(text)")
    let encoded = try JSONEncoder().encode(record.speakers[1])
    precondition(String(decoding: encoded, as: UTF8.self).contains("\"known-voice\""))

    func names(_ result: TranscriptSegments, _ roster: ParticipantRoster?, _ voices: VoiceProfiles)
      -> [String?]
    {
      var voices = voices
      return known(result, roster, in: &voices).names
    }
    let unnamed = { (names: [String?]) in names.allSatisfy { $0 == nil } }
    precondition(
      unnamed(names(recording([("S1", voice(anna, 0.75, toward: axis(2)), 20)]), tiles, profiles)),
      "A voice that only resembles a profile stays anonymous")
    precondition(
      unnamed(names(recording([("S1", voice(anna, 0.9, toward: axis(2)), 4)]), tiles, profiles)),
      "Too little speech names nobody")
    precondition(
      unnamed(names(meeting, roster(["Lena Hoffmann", "Marco Rossi"], full: true), profiles))
        && names(meeting, roster(["Anna Schmidt", "Marco Rossi"], full: true), profiles)[1]
          == "Anna Schmidt",
      "With the full participant list only its people can be recognized")
    var twins = profiles
    twins.profiles.append(
      .init(
        name: "Sam Carter",
        samples: [.init(vector: voice(anna, 0.85, toward: sam), seconds: 20, recordedAt: date)]))
    precondition(
      unnamed(names(recording([("S1", voice(anna, 0.95, toward: sam), 20)]), tiles, twins)),
      "Two profiles that both resemble the voice name nobody")
    var own = VoiceProfiles()
    own.profiles = [
      .init(
        name: "Jona", samples: [.init(vector: anna.map(Float.init), seconds: 20, recordedAt: date)])
    ]
    precondition(unnamed(names(meeting, tiles, own)), "Your own name never names a remote voice")

    let decisions: [SpeakerFusion.Decision] = [
      .init(name: nil, reason: .unidentified), .init(name: "Lena Hoffmann", reason: .teamsReading),
      .init(name: nil, reason: .unidentified), .init(name: nil, reason: .unidentified),
      .init(name: nil, reason: .unidentified),
    ]
    var partly = profiles
    let contradicted = known(meeting, tiles, naming: decisions, in: &partly)
    precondition(
      unnamed(contradicted.names) && !contradicted.learned,
      "Teams evidence for another name outweighs a profile, and a partly named voice teaches nothing"
    )
    let shown = decisions.map {
      SpeakerFusion.Decision(name: $0.name == nil ? nil : "Anna Schmidt", reason: $0.reason)
    }
    precondition(
      names(meeting, tiles, profiles).elementsEqual(
        known(meeting, tiles, naming: shown, in: &partly).names.enumerated().map {
          $0.offset == 1 ? "Anna Schmidt" : $0.element
        }),
      "A profile completes a voice Teams named in part")

    var shared = VoiceProfiles()
    let room = recording([("S1", anna.map(Float.init), 20), ("S2", sam.map(Float.init), 10)])
    precondition(
      !known(room, roster(["Anna Schmidt"]), in: &shared).learned,
      "Two voices under the only remote participant's name teach nothing")
    var named = VoiceProfiles()
    let all: [SpeakerFusion.Decision] = [
      .init(name: nil, reason: .unidentified), .init(name: "Lena Hoffmann", reason: .teamsReading),
      .init(name: "Lena Hoffmann", reason: .voiceOfNamedCluster),
      .init(name: "Marco Rossi", reason: .teamsReading), .init(name: nil, reason: .unidentified),
    ]
    precondition(
      known(meeting, tiles, naming: all, in: &named).learned
        && named.profiles.map(\.name) == ["Lena Hoffmann"],
      "A voice teaches when Teams evidence names all of it: \(named.profiles.map(\.name))")
    for _ in 0..<10 { _ = known(call, roster(["anna schmidt"]), in: &profiles) }
    precondition(
      profiles.profiles.count == 1
        && profiles.profiles[0].samples.count == VoiceProfiles.samplesPerName)

    let file = directory.appendingPathComponent("voices/voices.json")
    let store = VoiceProfileStore(file: file)
    precondition(store.load() == VoiceProfiles())
    try store.update {
      $0 = profiles
      return false
    }
    precondition(!FileManager.default.fileExists(atPath: file.path))
    try store.update {
      $0 = profiles
      return true
    }
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    precondition(store.load() == profiles && (mode as? NSNumber)?.intValue == 0o600)
    store.removeAll()
    precondition(store.load() == VoiceProfiles())

    var config = try AppConfig.parse(Data("{}".utf8)).config
    precondition(config.recognizeVoices)
    SettingsChange(recognizeVoices: false).apply(to: &config)
    let saved = try AppConfig.parse(config.encoded()).config
    precondition(!saved.recognizeVoices)
    print("Voices of named speakers name later anonymous voices above the matching bar: OK")
  }
}

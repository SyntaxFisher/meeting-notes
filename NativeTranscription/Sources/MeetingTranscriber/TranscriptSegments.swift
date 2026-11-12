import Foundation

/// The transcription helper's machine-readable result, shared by the helper and the app.
struct TranscriptSegments: Codable, Equatable {
  enum Mode: String, Codable {
    /// The microphone and system tracks were transcribed separately: microphone speech is the
    /// local participant and the system track (Teams, one other app, or device audio) is
    /// diarized into remote voices.
    case separateTracks = "separate-tracks"
    /// One mixed recording was diarized into anonymous voices.
    case mixed
  }

  enum Source: String, Codable {
    case microphone, teams, mix
    /// The system track of a recording that captured all device audio instead of Teams.
    case deviceAudio = "device-audio"
    /// The system track of a recording that captured one app other than Teams; the meeting
    /// record's `source` names it.
    case app

    /// The source of the system track in a capture whose `capture.json` has this `systemAudio`.
    init(systemAudio: String?) {
      switch systemAudio {
      case "device-audio": self = .deviceAudio
      case let scope? where scope.hasPrefix("app:"): self = .app
      default: self = .teams
      }
    }
  }

  struct Segment: Codable, Equatable {
    var start: Double
    var end: Double
    var source: Source
    /// Stable within one result: "local", or the diarizer's cluster for system or mixed audio.
    var speaker: String
    var text: String
  }

  /// Speaker embeddings are evidence for naming voices. They are not stored in meeting
  /// records; the app keeps the voices of named speakers apart from them, when that is on.
  struct VoiceEmbedding: Codable, Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var values: [Float]
  }

  /// How much of the microphone track was attributed to playback picked up acoustically: the
  /// estimated acoustic delay, the echo level relative to the system track (0 when no echo
  /// was found), the seconds of microphone speech discarded as echo, and the recognized
  /// microphone words dropped because they repeated the system track.
  struct EchoReport: Codable, Equatable {
    var lagSeconds: Double
    var coupling: Double
    var discardedSeconds: Double
    var copiedWords: Int? = nil
  }

  /// What recognition started from, so a transcription can be analyzed and repeated later: the
  /// diarizer's turns of the system or mixed audio, the microphone ranges kept as local speech,
  /// and each model file's SHA-256 by name.
  struct Diagnostics: Codable, Equatable {
    struct Span: Codable, Equatable {
      var start: Double
      var end: Double
      var speaker: String
    }
    var turns: [Span]
    var localSpeech: [Span]
    var models: [String: String]
  }

  var mode: Mode
  var duration: Double
  var segments: [Segment]
  var echo: EchoReport? = nil
  var voiceEmbeddings: [VoiceEmbedding]? = nil
  var diagnostics: Diagnostics? = nil
  /// The recognition and diarization models that produced the segments.
  var engine: String
}

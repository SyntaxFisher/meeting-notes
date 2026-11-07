import Foundation

/// Where a meeting is in its lifecycle. The app writes every change to the meeting's record, so
/// the record file always says what is happening to it.
enum MeetingStatus: String, Codable, CaseIterable, Sendable {
  /// Audio is being captured.
  case recording
  /// The recording stopped and its tracks are being mixed into the saved audio.
  case saving
  /// The audio is saved and waits in the transcription queue.
  case queued
  /// The transcription engine is working on this meeting; see `stage` and `progress`.
  case transcribing
  /// The transcript is saved.
  case complete
  /// Saving or transcription failed; see `error`. Retry or discard it.
  case failed
  /// Meeting Notes quit while recording or saving. Retry recovers what was captured.
  case interrupted
  /// Audio an older version saved but never transcribed, recorded by the file migration.
  /// Transcribe or discard it. New recordings never get this status.
  case untranscribed

  /// Work that still needs a decision from the user.
  var needsAttention: Bool { self == .failed || self == .interrupted || self == .untranscribed }
  /// Work the app is doing right now or will do without being asked.
  var isInProgress: Bool {
    self == .recording || self == .saving || self == .queued || self == .transcribing
  }
}

/// What a recording captured besides the microphone, stored as `teams`, `device-audio`,
/// `app:<bundle id>` or `microphone`.
enum MeetingSource: RawRepresentable, Codable, Hashable, Sendable {
  /// The microphone and Teams playback.
  case teams
  /// The microphone and everything else this Mac played.
  case deviceAudio
  /// The microphone and the playback of the app with this bundle ID.
  case app(String)
  /// The microphone only.
  case microphone

  init(_ systemAudio: SystemAudioScope?) {
    switch systemAudio {
    case .teams: self = .teams
    case .deviceAudio: self = .deviceAudio
    case .app(let bundleID): self = .app(bundleID)
    case nil: self = .microphone
    }
  }

  init?(rawValue: String) {
    if rawValue == "microphone" {
      self = .microphone
    } else if let scope = SystemAudioScope(rawValue: rawValue) {
      self.init(scope)
    } else {
      return nil
    }
  }

  var rawValue: String { systemAudio?.rawValue ?? "microphone" }

  var systemAudio: SystemAudioScope? {
    switch self {
    case .teams: .teams
    case .deviceAudio: .deviceAudio
    case .app(let bundleID): .app(bundleID)
    case .microphone: nil
    }
  }

  /// How the recording is described to people, such as "Zoom audio + microphone".
  var summary: String {
    systemAudio.map { "\($0.label) + microphone" } ?? "microphone only"
  }
}

enum MeetingTrigger: String, Codable, Sendable {
  case automatic, manual
}

struct MeetingSpeaker: Codable, Equatable, Sendable {
  enum Identity: String, Codable, Sendable {
    /// Everything the local microphone recorded.
    case localUser = "local-user"
    /// Teams audio while Teams listed exactly one other participant.
    case soleRemoteParticipant = "sole-remote-participant"
    /// A voice told apart by sound only.
    case unidentified
  }

  /// The label in the transcript text, which never changes.
  var label: String
  /// A name assigned later by a person or an agent.
  var name: String?
  var isLocalUser = false
  var identity: Identity = .unidentified
  var source: TranscriptSegments.Source?
  /// The Teams participant this speaker was matched to.
  var participant: String?
  var turns = 0
  var seconds = 0.0

  var displayName: String { name ?? label }

  enum CodingKeys: String, CodingKey {
    case label, name, identity, source, participant, turns, seconds
    case isLocalUser = "is_local_user"
  }

  init(
    label: String, name: String? = nil, isLocalUser: Bool = false,
    identity: Identity = .unidentified, source: TranscriptSegments.Source? = nil,
    participant: String? = nil, turns: Int = 0, seconds: Double = 0
  ) {
    self.label = label
    self.name = name
    self.isLocalUser = isLocalUser
    self.identity = identity
    self.source = source
    self.participant = participant
    self.turns = turns
    self.seconds = seconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    label = try container.decode(String.self, forKey: .label)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    isLocalUser = try container.decodeIfPresent(Bool.self, forKey: .isLocalUser) ?? false
    identity = try container.decodeIfPresent(Identity.self, forKey: .identity) ?? .unidentified
    source = try container.decodeIfPresent(TranscriptSegments.Source.self, forKey: .source)
    participant = try container.decodeIfPresent(String.self, forKey: .participant)
    turns = try container.decodeIfPresent(Int.self, forKey: .turns) ?? 0
    seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
  }
}

struct MeetingSegment: Codable, Equatable, Sendable {
  var start: Double
  var end: Double
  var speaker: String
  var text: String
}

struct MeetingTranscription: Codable, Equatable, Sendable {
  var mode: TranscriptSegments.Mode
  var engine: String
  var echo: TranscriptSegments.EchoReport?
}

/// The single machine-readable record of one meeting, stored as `transcripts/<id>.json`. It is
/// created when recording starts and updated at every lifecycle step. Requested edits update
/// this record and the current `.txt` transcript together.
struct MeetingRecord: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion = MeetingRecord.currentSchemaVersion
  /// The UTC start time, such as `20261105T145000Z`. Every file of the meeting is named
  /// `<id>.<extension>`.
  var id: String
  var title: String?
  var titleSource: MeetingTitleSource
  var summary: String?
  var startedAt: Date
  var endedAt: Date?
  var durationSeconds: Double?
  var source: MeetingSource?
  var trigger: MeetingTrigger?
  var status: MeetingStatus
  /// The transcription engine's current step while transcribing.
  var stage: String?
  /// Completed fraction while transcribing, when the engine can measure it.
  var progress: Double?
  var queuedAt: Date?
  var error: String?
  var failedAt: Date?
  /// File names inside the audios and transcripts folders.
  var audioFile: String?
  var transcriptFile: String?
  var speakers: [MeetingSpeaker] = []
  var participants: ParticipantRoster?
  var transcription: MeetingTranscription?
  var segments: [MeetingSegment] = []
  var revision = 0
  var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id, title, summary
    case titleSource = "title_source"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case durationSeconds = "duration_seconds"
    case source, trigger, status, stage, progress
    case queuedAt = "queued_at"
    case error
    case failedAt = "failed_at"
    case audioFile = "audio_file"
    case transcriptFile = "transcript_file"
    case speakers, participants, transcription, segments
    case revision
    case updatedAt = "updated_at"
  }

  init(
    id: String, title: String? = nil, startedAt: Date, status: MeetingStatus,
    source: MeetingSource? = nil, trigger: MeetingTrigger? = nil,
    titleSource: MeetingTitleSource? = nil
  ) {
    self.id = id
    self.title = title
    self.titleSource = titleSource ?? .inferred(title: title, source: source)
    self.startedAt = startedAt
    self.status = status
    self.source = source
    self.trigger = trigger
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container,
        debugDescription: "Unsupported schema version \(schemaVersion)")
    }
    id = try container.decode(String.self, forKey: .id)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
    source = try container.decodeIfPresent(MeetingSource.self, forKey: .source)
    trigger = try container.decodeIfPresent(MeetingTrigger.self, forKey: .trigger)
    status = try container.decode(MeetingStatus.self, forKey: .status)
    stage = try container.decodeIfPresent(String.self, forKey: .stage)
    progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    queuedAt = try container.decodeIfPresent(Date.self, forKey: .queuedAt)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    failedAt = try container.decodeIfPresent(Date.self, forKey: .failedAt)
    audioFile = try container.decodeIfPresent(String.self, forKey: .audioFile)
    transcriptFile = try container.decodeIfPresent(String.self, forKey: .transcriptFile)
    speakers = try container.decodeIfPresent([MeetingSpeaker].self, forKey: .speakers) ?? []
    participants = try container.decodeIfPresent(ParticipantRoster.self, forKey: .participants)
    transcription = try container.decodeIfPresent(
      MeetingTranscription.self, forKey: .transcription)
    segments = try container.decodeIfPresent([MeetingSegment].self, forKey: .segments) ?? []
    revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    titleSource =
      try container.decodeIfPresent(MeetingTitleSource.self, forKey: .titleSource)
      ?? .inferred(title: title, source: source)
  }

  var displayTitle: String { title ?? "Untitled meeting" }

  func displayName(for label: String) -> String {
    speakers.first { $0.label == label }?.displayName ?? label
  }

  /// Rounds a duration to hundredths of a second for stable, readable records.
  static func seconds(_ value: Double) -> Double { (value * 100).rounded() / 100 }

  /// Derives speakers in order of first appearance, keeping what is already known about them.
  static func speakers(for segments: [MeetingSegment], keeping existing: [MeetingSpeaker] = [])
    -> [MeetingSpeaker]
  {
    var seen: [String] = []
    for segment in segments where !seen.contains(segment.speaker) { seen.append(segment.speaker) }
    return seen.map { label in
      existing.first { $0.label == label } ?? MeetingSpeaker(label: label)
    }
  }
}

/// What a failed or interrupted meeting has on disk, which decides what Retry can do.
struct MeetingWork: Equatable, Sendable {
  var audio: URL?
  var capture: URL?
  var hasCapturedAudio: Bool {
    capture.map {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("capture.json").path)
    } ?? false
  }
  var canRetry: Bool { audio != nil || hasCapturedAudio }
}

import Foundation

/// Transcription progress as reported by the helper's `stage` field.
struct TranscriptionProgress: Equatable, Sendable {
  enum Stage: Equatable, Sendable {
    case starting
    case speakerModels
    case downloadingModel(percent: Int)
    case identifyingSpeakers
    case findingSpeech
    case transcriptionModel
    case detectingLanguages
    case transcribing(part: Int, of: Int)
    case saving
  }

  var stage: Stage

  init(stage: Stage = .starting) { self.stage = stage }

  init(helperStage: String) {
    if let match = helperStage.firstMatch(of: #/^Transcribing part (\d+)/(\d+)$/#),
      let part = Int(match.1), let total = Int(match.2), total > 0
    {
      stage = .transcribing(part: part, of: total)
      return
    }
    if let match = helperStage.firstMatch(of: #/^Downloading the transcription model (\d+)%$/#),
      let percent = Int(match.1)
    {
      stage = .downloadingModel(percent: min(100, percent))
      return
    }
    switch helperStage {
    case "Preparing speaker models": stage = .speakerModels
    case "Identifying speakers", "Identifying remote speakers", "Finding your speech":
      stage = .identifyingSpeakers
    case "Finding speech": stage = .findingSpeech
    case "Preparing whisper large-v3-turbo": stage = .transcriptionModel
    case "Detecting languages": stage = .detectingLanguages
    case "Complete": stage = .saving
    default: stage = .starting
    }
  }

  /// Reads back a `description` stored in a meeting record.
  init(recordStage: String) {
    if let match = recordStage.firstMatch(of: #/^Transcribing part (\d+) of (\d+)$/#),
      let part = Int(match.1), let total = Int(match.2), total > 0
    {
      stage = .transcribing(part: part, of: total)
      return
    }
    if let match = recordStage.firstMatch(
      of: #/^Downloading the transcription model \((\d+)%, once\)$/#),
      let percent = Int(match.1)
    {
      stage = .downloadingModel(percent: min(100, percent))
      return
    }
    let stages: [Stage] = [
      .speakerModels, .identifyingSpeakers, .findingSpeech, .transcriptionModel,
      .detectingLanguages, .saving,
    ]
    stage =
      stages.first { TranscriptionProgress(stage: $0).description == recordStage } ?? .starting
  }

  var description: String {
    switch stage {
    case .starting: return "Starting the transcription engine"
    case .speakerModels: return "Loading speaker models"
    case .downloadingModel(let percent):
      return "Downloading the transcription model (\(percent)%, once)"
    case .identifyingSpeakers: return "Identifying speakers"
    case .findingSpeech: return "Finding speech"
    case .transcriptionModel: return "Loading the transcription model"
    case .detectingLanguages: return "Detecting languages"
    case .transcribing(let part, let total): return "Transcribing part \(part) of \(total)"
    case .saving: return "Saving the transcript"
    }
  }

  /// Determinate progress exists while the model downloads and while parts are transcribed.
  var fraction: Double? {
    switch stage {
    case .downloadingModel(let percent): return Double(percent) / 100
    case .transcribing(let part, let total): return Double(max(0, part - 1)) / Double(total)
    case .saving: return 1
    default: return nil
    }
  }
}

/// A problem that does not belong to a meeting, such as a recording that could not start.
/// Meeting failures live in their records instead.
struct AppProblem: Equatable {
  var title: String
  var reason: String
  var date: Date
}

enum ReadyContext: Equatable {
  case manual
  case autoRecord
  case autoRecordPaused
}

enum StatusTone: Equatable {
  case neutral, recording, muted, working, success, warning, error
}

/// What clicking the panel header does. The header is the record control: it starts and stops
/// recordings, and leads to the fix when recording is impossible.
enum HeaderAction: Equatable {
  case start, stop, setUpPermissions, openFolderSettings

  var title: String {
    switch self {
    case .start: return "Start Recording"
    case .stop: return "Stop and Transcribe"
    case .setUpPermissions: return "Set Up Permissions"
    case .openFolderSettings: return "Open Files and Folders Settings"
    }
  }
}

/// The secondary button the panel header reveals on hover.
enum HeaderAccessory: Equatable {
  /// Stops the recording in progress and moves it to the Trash.
  case discardRecording
  /// Cancels saving or transcription and moves that meeting to the Trash.
  case discardMeeting(id: String)
  case dismissProblem

  var title: String {
    switch self {
    case .discardRecording: return "Discard Recording"
    case .discardMeeting: return "Cancel and Discard"
    case .dismissProblem: return "Dismiss"
    }
  }

  var symbol: String {
    switch self {
    case .discardRecording, .discardMeeting: return "trash"
    case .dismissProblem: return "xmark"
    }
  }

  var help: String {
    switch self {
    case .discardRecording:
      return "Stop and move this recording to the Trash without transcribing it (⌘⌫)"
    case .discardMeeting:
      return "Stop processing and move this meeting to the Trash without a transcript (⌘⌫)"
    case .dismissProblem: return "Dismiss"
    }
  }
}

/// What the panel header and the menu bar icon say is happening, derived from app state only.
/// A recording always wins, then an unreadable meetings folder, missing permissions,
/// transcription, meetings that need attention, other problems, a fresh transcript, any other
/// reason recording is unavailable, and finally "Ready".
enum PanelStatus: Equatable {
  case folderUnavailable(folder: String, denied: Bool)
  case setupRequired([MeetingPermission])
  case systemAudioBlocked
  case ready(ReadyContext)
  /// Recording is impossible for another reason, such as an update being installed.
  case unavailable(reason: String)
  case starting
  case recording(startedAt: Date, title: String?, mutedInTeams: Bool)
  case saving(id: String, title: String?)
  case transcribing(TranscriptionProgress, id: String, title: String?, waiting: Int)
  case attention(count: Int)
  case problem(AppProblem)
  case transcriptReady(id: String, title: String)

  struct Inputs {
    var permissions: PermissionSnapshot
    var folderAccess = MeetingsFolderAccess.granted
    var folderName = "the meetings folder"
    var systemAudioBlocked = false
    var starting = false
    var recording: MeetingRecord? = nil
    var mutedInTeams = false
    var saving: MeetingRecord? = nil
    var transcribing: MeetingRecord? = nil
    var progress = TranscriptionProgress()
    var waiting = 0
    var attentionCount = 0
    var problem: AppProblem? = nil
    var freshTranscript: MeetingRecord? = nil
    /// Why a recording cannot start, when no earlier state explains it.
    var startBlocked: String? = nil
    var autoRecord = false
    var autoRecordPaused = false
  }

  static func make(_ inputs: Inputs) -> PanelStatus {
    if let recording = inputs.recording {
      return .recording(
        startedAt: recording.startedAt, title: recording.title, mutedInTeams: inputs.mutedInTeams)
    }
    if inputs.starting { return .starting }
    switch inputs.folderAccess {
    case .granted: break
    case .checking: return .folderUnavailable(folder: inputs.folderName, denied: false)
    case .denied: return .folderUnavailable(folder: inputs.folderName, denied: true)
    }
    let missing = inputs.permissions.missingForRecording()
    if !missing.isEmpty { return .setupRequired(missing) }
    if inputs.systemAudioBlocked {
      return .systemAudioBlocked
    }
    if let transcribing = inputs.transcribing {
      return .transcribing(
        inputs.progress, id: transcribing.id, title: transcribing.title, waiting: inputs.waiting)
    }
    if let saving = inputs.saving { return .saving(id: saving.id, title: saving.title) }
    if inputs.attentionCount > 0 { return .attention(count: inputs.attentionCount) }
    if let problem = inputs.problem { return .problem(problem) }
    if let fresh = inputs.freshTranscript {
      return .transcriptReady(id: fresh.id, title: fresh.displayTitle)
    }
    if let reason = inputs.startBlocked { return .unavailable(reason: reason) }
    if !inputs.autoRecord { return .ready(.manual) }
    return .ready(inputs.autoRecordPaused ? .autoRecordPaused : .autoRecord)
  }

  /// Background work belongs to its meeting row; the header describes recording availability.
  static func header(_ inputs: Inputs) -> PanelStatus {
    var recording = inputs
    recording.saving = nil
    recording.transcribing = nil
    recording.attentionCount = 0
    recording.freshTranscript = nil
    return make(recording)
  }

  /// The folder name people know, such as "Documents" for ~/Documents/meeting-notes.
  static func folderName(of root: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
    let parts = root.standardizedFileURL.pathComponents
    if parts.count > home.count, Array(parts.prefix(home.count)) == home {
      return parts[home.count]
    }
    return root.lastPathComponent
  }

  /// A status word or short phrase.
  func headline(now: Date) -> String {
    switch self {
    case .folderUnavailable(let folder, let denied):
      return denied ? "No access to \(folder)" : "Waiting for access to \(folder)"
    case .setupRequired: return "Setup required"
    case .systemAudioBlocked: return "System audio blocked"
    case .attention: return "Needs attention"
    case .problem(let problem): return problem.title
    case .ready: return "Ready"
    case .unavailable: return "Recording unavailable"
    case .starting: return "Starting…"
    case .recording(let startedAt, _, _):
      return "Recording \(Self.elapsed(now.timeIntervalSince(startedAt)))"
    case .saving: return "Processing"
    case .transcribing(let progress, _, _, _):
      return progress.stage == .saving ? "Finishing" : "Transcribing"
    case .transcriptReady: return "Transcript ready"
    }
  }

  /// The meeting the header names: the recording or the meeting being processed.
  var meetingTitle: String? {
    switch self {
    case .recording(_, let title, _), .saving(_, let title), .transcribing(_, _, let title, _):
      return title ?? "Untitled meeting"
    default: return nil
    }
  }

  /// One short line, only when it changes what the user should do or know.
  var detail: String? {
    switch self {
    case .folderUnavailable(_, true):
      return "Allow it in Privacy & Security > Files and Folders."
    case .systemAudioBlocked: return "Allow it in Screen & System Audio Recording."
    case .ready(.autoRecordPaused): return "Auto-record resumes after this meeting."
    case .unavailable(let reason): return reason
    case .recording(_, _, true): return "Muted in Teams"
    case .problem(let problem): return problem.reason
    default: return nil
    }
  }

  /// Everything the header says, for the menu bar tooltip and VoiceOver.
  func spokenSummary(now: Date) -> String {
    var parts = [headline(now: now)]
    if let meetingTitle { parts.append(meetingTitle) }
    if let detail { parts.append(detail) }
    if case .transcribing(let progress, _, _, let waiting) = self {
      parts.append(progress.description)
      if waiting > 0 { parts.append(waiting == 1 ? "1 more waiting" : "\(waiting) more waiting") }
    }
    return parts.joined(separator: ". ")
  }

  var tone: StatusTone {
    switch self {
    case .folderUnavailable(_, let denied): return denied ? .warning : .working
    case .setupRequired, .systemAudioBlocked: return .warning
    case .attention, .problem: return .error
    case .ready, .unavailable: return .neutral
    case .starting, .saving, .transcribing: return .working
    case .recording(_, _, let muted): return muted ? .muted : .recording
    case .transcriptReady: return .success
    }
  }

  var symbol: String {
    switch self {
    case .folderUnavailable(_, let denied): return denied ? "lock.shield" : "hourglass"
    case .setupRequired, .systemAudioBlocked: return "lock.shield"
    case .attention, .problem: return "exclamationmark.triangle.fill"
    case .ready: return "waveform"
    case .unavailable: return "pause.circle"
    case .starting, .saving: return "hourglass"
    case .recording(_, _, let muted): return muted ? "mic.slash.fill" : "waveform"
    case .transcribing: return "text.bubble"
    case .transcriptReady: return "checkmark.circle.fill"
    }
  }

  var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }

  /// What clicking the header does, or nil when recording is impossible for a reason the panel
  /// cannot fix. Earlier meetings that are saving or transcribing never keep the header from
  /// starting the next recording.
  func headerAction(canStart: Bool) -> HeaderAction? {
    switch self {
    case .recording: return .stop
    case .setupRequired, .systemAudioBlocked: return .setUpPermissions
    case .folderUnavailable(_, true): return .openFolderSettings
    case .folderUnavailable(_, false), .starting, .unavailable: return nil
    case .ready, .saving, .transcribing, .attention, .problem, .transcriptReady:
      return canStart ? .start : nil
    }
  }

  var headerAccessory: HeaderAccessory? {
    switch self {
    case .recording: return .discardRecording
    case .saving(let id, _), .transcribing(_, let id, _, _): return .discardMeeting(id: id)
    case .problem: return .dismissProblem
    default: return nil
    }
  }

  /// A short phrase VoiceOver announces when the status kind changes.
  var announcement: String {
    switch self {
    case .recording(_, _, true): return "Muted in Teams"
    case .recording: return "Recording started"
    default: return headline(now: Date())
    }
  }

  var kindIdentifier: String {
    switch self {
    case .folderUnavailable(_, let denied): return denied ? "folder-denied" : "folder-waiting"
    case .setupRequired: return "setup-required"
    case .systemAudioBlocked: return "system-audio-blocked"
    case .attention: return "needs-attention"
    case .problem: return "problem"
    case .ready: return "ready"
    case .unavailable: return "unavailable"
    case .starting: return "starting"
    case .recording(_, _, let muted): return muted ? "muted" : "recording"
    case .saving: return "saving"
    case .transcribing: return "transcribing"
    case .transcriptReady: return "transcript-ready"
    }
  }

  static func elapsed(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let rest = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }

  static func list(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
  }
}

/// Processing meetings stay visible until they finish, alongside the newest completed meetings.
enum PanelMeetings {
  static func recent(records: [MeetingRecord], pending: [MeetingRecord]) -> [MeetingRecord] {
    var current: [String: MeetingRecord] = [:]
    for record in records + pending { current[record.id] = record }
    let candidates = current.values.filter {
      $0.status == .complete || ($0.status.isInProgress && $0.status != .recording)
    }
    let selected = candidates.sorted { left, right in
      if priority(left) != priority(right) { return priority(left) < priority(right) }
      return newer(left, than: right)
    }.prefix(3)
    return selected.sorted { newer($0, than: $1) }
  }

  private static func priority(_ record: MeetingRecord) -> Int {
    switch record.status {
    case .transcribing: return 0
    case .saving: return 1
    case .queued: return 2
    default: return 3
    }
  }

  private static func newer(_ left: MeetingRecord, than right: MeetingRecord) -> Bool {
    if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
    return left.id > right.id
  }
}

import Foundation

extension Smoke {
  static func testStatus(root: URL) throws {
    testTranscriptionProgress()
    testPanelStatus()
    testPanelMeetings()
    try testStorage(root: root.appendingPathComponent("storage"))
    for permission in MeetingPermission.setupOrder {
      precondition(permission.settingsURL.scheme == "x-apple.systempreferences")
      precondition(!permission.explanation.isEmpty)
    }
    precondition(MeetingPermission.microphone.settingsURL.query == "Privacy_Microphone")
    precondition(MeetingPermission.systemAudio.settingsURL.query == "Privacy_ScreenCapture")
    precondition(MeetingPermission.accessibility.settingsURL.query == "Privacy_Accessibility")
    print("Status panel and storage usage: OK")
  }

  private static func testTranscriptionProgress() {
    let stages: [(String, TranscriptionProgress.Stage)] = [
      ("Preparing speaker models", .speakerModels),
      ("Identifying speakers", .identifyingSpeakers),
      ("Identifying remote speakers", .identifyingSpeakers),
      ("Finding your speech", .identifyingSpeakers),
      ("Downloading the transcription model 42%", .downloadingModel(percent: 42)),
      ("Finding speech", .findingSpeech),
      ("Preparing whisper large-v3-turbo", .transcriptionModel),
      ("Detecting languages", .detectingLanguages),
      ("Transcribing part 3/11", .transcribing(part: 3, of: 11)),
      ("Complete", .saving),
      ("Something new", .starting),
      ("Transcribing part 1/0", .starting),
    ]
    for (text, stage) in stages {
      let progress = TranscriptionProgress(helperStage: text)
      precondition(progress.stage == stage, "\(text) parsed as \(progress.stage)")
      precondition(
        TranscriptionProgress(recordStage: progress.description) == progress,
        "\(progress.description) reads back")
    }
    let part = TranscriptionProgress(helperStage: "Transcribing part 3/11")
    precondition(part.description == "Transcribing part 3 of 11")
    precondition(abs(part.fraction! - 2.0 / 11.0) < 0.0001)
    let download = TranscriptionProgress(helperStage: "Downloading the transcription model 42%")
    precondition(download.description == "Downloading the transcription model (42%, once)")
    precondition(download.fraction == 0.42)
    precondition(TranscriptionProgress(stage: .identifyingSpeakers).fraction == nil)
  }

  private static func testPanelStatus() {
    let granted = PermissionSnapshot(
      microphone: true, systemAudio: true, accessibility: true)
    let missing = PermissionSnapshot(
      microphone: true, systemAudio: false, accessibility: false)
    let start = Date(timeIntervalSince1970: 1_000)
    let recording = MeetingRecord(
      id: "20261105T100000Z", title: "Weekly Sync", startedAt: start, status: .recording)
    var queued = MeetingRecord(
      id: "20261105T090000Z", title: "Standup", startedAt: start, status: .transcribing)
    queued.stage = "Transcribing part 3 of 11"
    var inputs = PanelStatus.Inputs(permissions: granted)
    let ready = PanelStatus.make(inputs)
    precondition(ready == .ready(.manual))
    precondition(ready.headerAction(canStart: true) == .start && ready.headerAccessory == nil)
    precondition(ready.headerAction(canStart: false) == nil, "A blocked header is not a button")
    inputs.startBlocked = "An update is being installed."
    let unavailable = PanelStatus.make(inputs)
    precondition(unavailable == .unavailable(reason: "An update is being installed."))
    precondition(unavailable.headline(now: start) == "Recording unavailable")
    precondition(unavailable.detail == "An update is being installed.")
    precondition(unavailable.headerAction(canStart: false) == nil)
    inputs.startBlocked = nil
    inputs.autoRecord = true
    precondition(PanelStatus.make(inputs) == .ready(.autoRecord))
    inputs.autoRecordPaused = true
    precondition(PanelStatus.make(inputs) == .ready(.autoRecordPaused))
    inputs.freshTranscript = queued
    precondition(PanelStatus.make(inputs) == .transcriptReady(id: queued.id, title: "Standup"))
    inputs.attentionCount = 2
    let attention = PanelStatus.make(inputs)
    precondition(attention == .attention(count: 2) && attention.tone == .error)
    precondition(attention.headline(now: start) == "Needs attention" && attention.detail == nil)
    precondition(attention.headerAction(canStart: true) == .start)
    inputs.saving = recording
    let saving = PanelStatus.make(inputs)
    precondition(saving == .saving(id: recording.id, title: "Weekly Sync"))
    precondition(
      saving.headline(now: start) == "Processing" && saving.meetingTitle == "Weekly Sync")
    precondition(saving.headerAccessory == .discardMeeting(id: recording.id))
    precondition(saving.headerAction(canStart: true) == .start, "Processing never blocks recording")
    precondition(PanelStatus.header(inputs) == .ready(.autoRecordPaused))
    let progress = TranscriptionProgress(stage: .transcribing(part: 3, of: 11))
    inputs.transcribing = queued
    inputs.progress = progress
    inputs.waiting = 1
    let transcribing = PanelStatus.make(inputs)
    precondition(
      transcribing == .transcribing(progress, id: queued.id, title: "Standup", waiting: 1),
      "Transcription wins over saving")
    precondition(transcribing.headline(now: start) == "Transcribing")
    precondition(transcribing.meetingTitle == "Standup" && transcribing.detail == nil)
    precondition(transcribing.spokenSummary(now: start).hasSuffix("1 more waiting"))
    precondition(transcribing.headerAccessory == .discardMeeting(id: queued.id))
    let recordingHeader = PanelStatus.header(inputs)
    precondition(recordingHeader == .ready(.autoRecordPaused))
    precondition(recordingHeader.headerAccessory == nil)
    precondition(recordingHeader.headerAction(canStart: true) == .start)
    precondition(transcribing.tone == .working, "The menu icon still shows background work")
    inputs.startBlocked = "An update is being installed."
    precondition(
      PanelStatus.header(inputs) == .unavailable(reason: "An update is being installed."))
    inputs.startBlocked = nil
    inputs.progress = TranscriptionProgress(stage: .saving)
    precondition(PanelStatus.header(inputs) == .ready(.autoRecordPaused))
    let finishing = PanelStatus.transcribing(
      TranscriptionProgress(stage: .saving), id: queued.id, title: "Standup", waiting: 0)
    precondition(finishing.headline(now: start) == "Finishing")
    inputs.recording = recording
    inputs.mutedInTeams = true
    let muted = PanelStatus.make(inputs)
    precondition(muted == .recording(startedAt: start, title: "Weekly Sync", mutedInTeams: true))
    precondition(muted.headline(now: start) == "Recording 0:00" && muted.tone == .muted)
    precondition(muted.detail == "Muted in Teams" && muted.meetingTitle == "Weekly Sync")
    precondition(muted.headerAction(canStart: false) == .stop)
    precondition(muted.headerAccessory == .discardRecording)
    precondition(HeaderAction.stop.title == "Stop and Transcribe")
    inputs.mutedInTeams = false
    let live = PanelStatus.make(inputs)
    precondition(live.headline(now: start.addingTimeInterval(754)) == "Recording 12:34")
    precondition(live.isRecording, "A recording wins over the queue and failures")
    precondition(PanelStatus.header(inputs) == live)
    precondition(live.detail == nil, "An unmuted recording needs no second line")
    inputs.recording = nil
    inputs.folderAccess = .checking
    inputs.folderName = "Documents"
    let waiting = PanelStatus.make(inputs)
    precondition(waiting == .folderUnavailable(folder: "Documents", denied: false))
    precondition(waiting.headline(now: start) == "Waiting for access to Documents")
    precondition(waiting.detail == nil)
    precondition(waiting.headerAction(canStart: false) == nil)
    precondition(PanelStatus.header(inputs) == waiting)
    inputs.folderAccess = .denied("Operation not permitted")
    let denied = PanelStatus.make(inputs)
    precondition(denied.tone == .warning)
    precondition(denied.headerAction(canStart: false) == .openFolderSettings)
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(
      PanelStatus.folderName(of: home.appendingPathComponent("Documents/meeting-notes"))
        == "Documents")
    precondition(PanelStatus.folderName(of: URL(fileURLWithPath: "/Volumes/Data/notes")) == "notes")
    var setupInputs = PanelStatus.Inputs(permissions: missing)
    setupInputs.attentionCount = 1
    let setup = PanelStatus.make(setupInputs)
    precondition(setup == .setupRequired([.systemAudio]))
    precondition(setup.headline(now: start) == "Setup required" && setup.detail == nil)
    precondition(setup.tone == .warning)
    precondition(setup.headerAction(canStart: false) == .setUpPermissions)
    precondition(setup.headerAccessory == nil)
    setupInputs.transcribing = queued
    precondition(PanelStatus.header(setupInputs) == setup)
    var recordingInputs = PanelStatus.Inputs(permissions: granted)
    recordingInputs.permissions.accessibility = false
    precondition(PanelStatus.make(recordingInputs) == .ready(.manual))
    recordingInputs.systemAudioBlocked = true
    precondition(PanelStatus.make(recordingInputs) == .systemAudioBlocked)
    var problemInputs = PanelStatus.Inputs(permissions: granted)
    problemInputs.problem = AppProblem(title: "Recording could not start", reason: "x", date: start)
    let problem = PanelStatus.make(problemInputs)
    precondition(problem.kindIdentifier == "problem")
    precondition(problem.headerAccessory == .dismissProblem)
    precondition(problem.headerAction(canStart: true) == .start, "Clicking retries the start")
    precondition(PanelStatus.elapsed(3_725) == "1:02:05")
  }

  private static func testPanelMeetings() {
    func record(_ index: Int, status: MeetingStatus = .complete) -> MeetingRecord {
      MeetingRecord(
        id: "meeting-\(index)", startedAt: Date(timeIntervalSince1970: Double(index)),
        status: status)
    }
    let completed = (1...5).map { record($0) }
    precondition(
      PanelMeetings.recent(records: completed, pending: []).map(\.id)
        == ["meeting-5", "meeting-4", "meeting-3"])
    let queued = record(1, status: .queued)
    var transcribing = queued
    transcribing.status = .transcribing
    transcribing.stage = "Transcribing part 3 of 11"
    transcribing.progress = 2.0 / 11.0
    let recent = PanelMeetings.recent(
      records: completed + [queued, record(6, status: .recording)], pending: [transcribing])
    precondition(
      recent.map(\.id) == ["meeting-5", "meeting-4", "meeting-1"],
      "Older processing remains visible within three rows; the recording stays in the header")
    precondition(recent.last == transcribing, "The engine's freshest state replaces library state")
    let saving = record(7, status: .saving)
    let withSaving = PanelMeetings.recent(records: completed, pending: [transcribing, saving])
    precondition(withSaving.map(\.id) == ["meeting-7", "meeting-5", "meeting-1"])
    let backlog = [transcribing] + (6...9).map { record($0, status: .queued) }
    precondition(
      PanelMeetings.recent(records: completed, pending: backlog).contains(transcribing),
      "The active transcription remains visible even with more than three queued meetings")
    precondition(PanelMeetings.recent(records: [record(6, status: .failed)], pending: []).isEmpty)
    precondition(PanelMeetings.recent(records: [], pending: []).isEmpty)
  }

  private static func testStorage(root: URL) throws {
    let manager = FileManager.default
    let audios = root.appendingPathComponent("audios")
    let transcripts = root.appendingPathComponent("transcripts")
    try manager.createDirectory(at: audios, withIntermediateDirectories: true)
    try manager.createDirectory(at: transcripts, withIntermediateDirectories: true)
    for name in ["20261103T090000Z.txt", "20261103T090000Z.json", "notes.txt"] {
      try Data(repeating: 65, count: 100).write(to: transcripts.appendingPathComponent(name))
    }
    try Data(repeating: 1, count: 1_000).write(
      to: audios.appendingPathComponent("20261105T100000Z.m4a"))
    try Data(repeating: 1, count: 500).write(to: audios.appendingPathComponent("keep-me.m4a"))
    let usage = RecordingRetention.usage(root: root)
    precondition(usage == RecordingRetention.Usage(audioBytes: 1_000, transcriptBytes: 200))
    precondition(
      RecordingRetention.usage(root: root.appendingPathComponent("missing"))
        == RecordingRetention.Usage())
  }

}

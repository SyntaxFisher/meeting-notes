import Foundation

extension Smoke {
  @MainActor
  static func testAutomation(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try testConfigParsing()
    try testConfigStore(root: root.appendingPathComponent("config"))
    print("config.json parsing, defaults, validation, round trip, reload and menu writes: OK")
    try testEventLog(root: root.appendingPathComponent("events"))
    print("events.jsonl lines and rotation: OK")
    testMeetingInfo()
    print("Meeting ids, speakers and event details: OK")
    try testSettingsChange()
    print("Settings changes: validation, storage keys, command-line sizes: OK")
    testURLCommands()
    print("meetingnotes:// commands: OK")
  }

  private static func parse(_ json: String) throws -> AppConfig.Parsed {
    try AppConfig.parse(Data(json.utf8))
  }

  private static func problems(_ json: String) -> [String] {
    do {
      _ = try parse(json)
      return []
    } catch let invalid as AppConfig.Invalid {
      return invalid.problems
    } catch {
      preconditionFailure("Unexpected error \(error)")
    }
  }

  private static func testConfigParsing() throws {
    let empty = try parse("{}")
    precondition(empty.config == AppConfig() && empty.warnings.isEmpty)
    precondition(empty.config.autoRecordTeamsMeetings && empty.config.mirrorTeamsMute)
    precondition(empty.config.keepAudio)
    precondition(empty.config.agentsMayNameMeetings && !empty.config.agentsMayCorrectTranscripts)
    precondition(empty.config.agentsMaySummarizeMeetings)
    let temporary = try AppConfig.parse(Data(#"{"keepAudio":false}"#.utf8)).config
    precondition(!temporary.keepAudio)
    let temporaryRoundTrip = try AppConfig.parse(temporary.encoded()).config
    precondition(!temporaryRoundTrip.keepAudio)
    precondition(empty.config.retention.audioBytes == 10_000_000_000)
    precondition(
      empty.config.meetingsRootURL.path
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Documents/meeting-notes"
        ).path)

    let full = try parse(
      """
      {
        "$schema": "https://example.invalid/schema.json",
        "autoRecordTeamsMeetings": false,
        "mirrorTeamsMute": false,
        "agentsMayNameMeetings": false,
        "agentsMaySummarizeMeetings": false,
        "agentsMayCorrectTranscripts": true,
        "localSpeakerName": "Jona B.",
        "retention": {"audioBytes": 5000}
      }
      """)
    precondition(full.warnings.isEmpty)
    precondition(!full.config.agentsMayNameMeetings && full.config.agentsMayCorrectTranscripts)
    precondition(!full.config.agentsMaySummarizeMeetings)
    precondition(full.config.localSpeakerName == "Jona B.")
    precondition(!full.config.autoRecordTeamsMeetings && !full.config.mirrorTeamsMute)
    precondition(full.config.retention.audioBytes == 5000)
    let roundTrip = try AppConfig.parse(full.config.encoded())
    precondition(roundTrip.config == full.config && roundTrip.warnings.isEmpty)
    let written = String(decoding: try AppConfig().encoded(), as: UTF8.self)

    let typo = try parse(
      #"{"autoRecord": true, "hooks": {"enabled": "x"}, "retention": {"audio": 5}}"#)
    precondition(typo.config == AppConfig())
    precondition(
      typo.warnings == [
        "Unknown setting autoRecord is ignored", "Unknown setting hooks is ignored",
        "Unknown setting retention.audio is ignored",
      ], "\(typo.warnings)")

    precondition(problems("{").first?.hasPrefix("config.json is not valid JSON") == true)
    precondition(problems("[]") == ["config.json must contain a JSON object"])
    precondition(
      problems(#"{"autoRecordTeamsMeetings": 1, "mirrorTeamsMute": "yes"}"#) == [
        "autoRecordTeamsMeetings must be true or false", "mirrorTeamsMute must be true or false",
      ])
    let fixedFolder = try parse(#"{"meetingsRoot": "/tmp/elsewhere"}"#)
    precondition(fixedFolder.config.meetingsRootURL == AppConfig().meetingsRootURL)
    precondition(!written.contains("meetingsRoot"))
    precondition(problems(#"{"retention": 5}"#) == ["retention must be a JSON object"])
    precondition(
      problems(#"{"localSpeakerName": "A: B"}"#) == [
        "localSpeakerName must be null or a name without a colon"
      ])
    precondition(
      problems(#"{"localSpeakerName": 3}"#) == ["localSpeakerName must be a string or null"])
    precondition(
      problems(#"{"retention": {"audioBytes": 0}}"#) == [
        "retention.audioBytes must be a whole number from 1 to 9223372036854775807"
      ])
    precondition(problems(#"{"retention": {"audioBytes": true}}"#).count == 1)
    precondition(
      problems(#"{"agentsMayCorrectTranscripts": 1}"#) == [
        "agentsMayCorrectTranscripts must be true or false"
      ])
    precondition(
      problems(#"{"agentsMaySummarizeMeetings": "yes"}"#) == [
        "agentsMaySummarizeMeetings must be true or false"
      ])
  }

  @MainActor
  private static func testConfigStore(root: URL) throws {
    let file = root.appendingPathComponent("config.json")
    let store = ConfigStore(file: file)
    var changes: [(AppConfig, AppConfig)] = []
    store.load()
    precondition(store.config == AppConfig() && store.isWritable)
    store.onChange = { changes.append(($0, $1)) }
    func onDisk() throws -> AppConfig { try AppConfig.parse(Data(contentsOf: file)).config }
    let created = try onDisk()
    precondition(created == AppConfig())
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    precondition(text.contains("\"localSpeakerName\" : null"), text)

    try store.update {
      $0.mirrorTeamsMute = false
    }
    precondition(!store.config.mirrorTeamsMute && changes.count == 1)
    let written = try onDisk()
    precondition(!written.mirrorTeamsMute)

    // Writing into the existing file, as `cp` or `echo >` do.
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(#"{"retention": {"audioBytes": 0}, "x": 1}"#.utf8))
    try handle.close()
    store.reload()
    precondition(
      store.status
        == .invalid("retention.audioBytes must be a whole number from 1 to 9223372036854775807"))
    precondition(!store.isWritable && !store.config.mirrorTeamsMute && changes.count == 1)
    do {
      try store.update { $0.mirrorTeamsMute = true }
      preconditionFailure("A broken config.json must not be overwritten from the UI")
    } catch {
      precondition(error.localizedDescription.contains("retention.audioBytes"))
    }
    do {
      try AppConfig.edit(file) { $0.mirrorTeamsMute = true }
      preconditionFailure("The command line must not overwrite a broken config.json either")
    } catch {}
    let untouched = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    precondition(untouched.contains("\"x\": 1"))

    try Data(#"{"x": 1}"#.utf8).write(to: file, options: .atomic)
    store.reload()
    precondition(store.status == .valid(warnings: ["Unknown setting x is ignored"]))
    precondition(store.config == AppConfig() && changes.count == 2)
    try store.update { $0.autoRecordTeamsMeetings = false }
    precondition(store.status == .valid(warnings: []) && changes.count == 3)
    // An agent edits the file; the next change from the UI keeps that edit.
    try AppConfig.edit(file) { $0.localSpeakerName = "Agent Name" }
    try store.update { $0.mirrorTeamsMute = false }
    precondition(store.config.localSpeakerName == "Agent Name" && !store.config.mirrorTeamsMute)
    let edited = try onDisk()
    precondition(!edited.mirrorTeamsMute && edited.localSpeakerName == "Agent Name")
  }

  private static func testEventLog(root: URL) throws {
    let file = root.appendingPathComponent("events.jsonl")
    let log = EventLog(file: file, maxBytes: 600)
    let time = Date(timeIntervalSince1970: 1_700_000_000)
    let line = try EventLog.line(
      time: time, event: "transcript.ready", meeting: "20261105T140300Z",
      details: ["transcriptPath": "/a/b.txt"])
    precondition(line.last == 0x0A)
    let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
    precondition(object["event"] as? String == "transcript.ready")
    precondition(object["meeting"] as? String == "20261105T140300Z")
    precondition((object["details"] as? [String: Any])?["transcriptPath"] as? String == "/a/b.txt")
    precondition((object["time"] as? String)?.isEmpty == false)
    let anonymous = try EventLog.line(time: time, event: "app.started", meeting: nil, details: [:])
    precondition(String(decoding: anonymous, as: UTF8.self).contains("\"meeting\":null"))

    for index in 0..<20 { log.record("test.event", meeting: "m\(index)", details: ["n": index]) }
    let current = try String(contentsOf: file, encoding: .utf8)
    let previous = try String(contentsOf: log.previousFile, encoding: .utf8)
    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
    precondition(size <= 600)
    let lines = (previous + current).split(separator: "\n")
    precondition(
      lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil })
    precondition(current.split(separator: "\n").last?.contains("\"meeting\":\"m19\"") == true)
    precondition(lines.count < 20 && lines.count > 1)
  }

  private static func testMeetingInfo() {
    let library = MeetingLibrary(root: URL(fileURLWithPath: "/m"))
    var record = MeetingRecord(
      id: "20261105T140300Z", title: "Weekly",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      status: .complete, trigger: .automatic)
    record.speakers = [
      MeetingSpeaker(label: "Jona", isLocalUser: true),
      MeetingSpeaker(label: "Speaker 1", name: "Ada"),
    ]
    var meeting = MeetingInfo(record: record, library: library)
    precondition(meeting.localSpeaker == "Jona")
    precondition(meeting.speakers == ["Jona", "Ada"] && meeting.automatic == true)
    precondition(meeting.transcriptPath == nil && meeting.recordPath == nil)
    meeting.durationSeconds = 61.26
    meeting.audioPath = "/m/audios/20261105T140300Z.m4a"
    meeting.transcriptPath = "/m/transcripts/20261105T140300Z.txt"
    meeting.speakers = ["Speaker 1", "Speaker 2"]
    let dictionary = meeting.dictionary
    precondition(dictionary["id"] as? String == "20261105T140300Z")
    precondition(dictionary["stem"] == nil)
    precondition(dictionary["durationSeconds"] as? Double == 61.3)
    let line = String(
      decoding: try! EventLog.line(
        time: Date(), event: LifecycleEvent.transcriptReady.rawValue, meeting: meeting.id,
        details: dictionary),
      as: UTF8.self)
    precondition(line.contains("\"durationSeconds\":61.3,"), line)
    precondition(dictionary["endedAt"] is NSNull)
    precondition(dictionary["speakers"] as? [String] == ["Speaker 1", "Speaker 2"])
    precondition(dictionary["automatic"] as? Bool == true)
  }

  private static func testSettingsChange() throws {
    precondition(SettingsChange().isEmpty && !SettingsChange(audioBytes: 5).isEmpty)
    try SettingsChange(audioBytes: 1).validate()
    for invalid in [
      SettingsChange(audioBytes: 0)
    ] {
      do {
        try invalid.validate()
        preconditionFailure("\(invalid) must be refused")
      } catch {}
    }
    var config = AppConfig()
    SettingsChange(audioBytes: 5).apply(to: &config)
    precondition(config.retention.audioBytes == 5)
    precondition(config.autoRecordTeamsMeetings)
    let status = StatusSnapshot.settings(config, file: URL(fileURLWithPath: "/c.json"), error: nil)
    precondition(
      status.meetingsRoot == "~/Documents/meeting-notes" && status.retentionAudioBytes == 5)
    let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
    precondition(!json.contains("retention_transcript_bytes"), json)

    precondition(CommandLineInterface.byteCount("20GB") == 20_000_000_000)
    precondition(CommandLineInterface.byteCount("1.5 tb") == 1_500_000_000_000)
    precondition(CommandLineInterface.byteCount("500MB") == 500_000_000)
    precondition(CommandLineInterface.byteCount("10000000000") == 10_000_000_000)
    for invalid in ["", "0", "GB", "-5GB", "5 PB", "1e30", "five"] {
      precondition(CommandLineInterface.byteCount(invalid) == nil, invalid)
    }
  }

  private static func testURLCommands() {
    func command(_ string: String) -> URLCommand? { URLCommand(url: URL(string: string)!) }
    precondition(command("meetingnotes://start") == .start(title: nil))
    precondition(
      command("meetingnotes://start?title=Design%20Review") == .start(title: "Design Review"))
    for source in ["us.zoom.xos", "microphone", "auto", "zoom"] {
      precondition(command("meetingnotes://start?source=\(source)") == nil)
    }
    precondition(command("MeetingNotes://STOP") == .stop)
    precondition(command("meetingnotes:discard") == nil, "Discarding is never a URL command")
    for removed in ["retry", "open", "library", "config"] {
      precondition(command("meetingnotes://" + removed) == nil)
      precondition(command("meetingnotes://" + removed + "?id=20261105T140300Z") == nil)
    }
    precondition(
      command("meetingnotes://meeting/20261105T140300Z?t=12")
        == .meeting(MeetingLink(meetingID: "20261105T140300Z", time: 12)))
    precondition(command("meetingnotes://reveal?id=") == .reveal(id: nil))
    precondition(command("meetingnotes://explode") == nil)
    precondition(command("https://start") == nil)
  }
}

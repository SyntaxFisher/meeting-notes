import AVFoundation
import Foundation

extension Smoke {
  static func testMeetingLinks() {
    func parse(_ string: String) -> MeetingLink? { MeetingLink(url: URL(string: string)!) }

    let base = MeetingLink.baseURL
    let link = MeetingLink(meetingID: "20261105T151700Z", time: 754)
    precondition(link.string == base + "20261105T151700Z?t=754", link.string)
    precondition(parse(link.string) == link)
    precondition(URLCommand(url: link.url) == .meeting(link))
    precondition(URLCommand(url: link.url)?.isNavigation == true)
    precondition(URLCommand(url: URL(string: "meetingnotes://start")!)?.isNavigation == false)

    for id in [
      "20261105T151700Z-2", "a?b#c&d=e%20f+g", "Größe 日本", "x;y,z:@!$'()*", " spaced ",
    ] {
      let link = MeetingLink(meetingID: id, time: 12.5)
      precondition(parse(link.string) == link, "\(id) must survive a round trip")
      let path = link.string.dropFirst(base.count).prefix { $0 != "?" }
      precondition(
        path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~%".contains($0)) },
        "\(link.string) must percent-encode the id")
      let native = link.string.replacingOccurrences(of: base, with: "meetingnotes://meeting/")
      precondition(parse(native) == link, "Existing native links must keep their exact target")
    }

    let plain = MeetingLink(meetingID: "20261105T151700Z")
    precondition(plain.string == base + "20261105T151700Z")
    precondition(parse(plain.string) == plain)
    precondition(parse("MeetingNotes://MEETING/20261105T151700Z/") == plain)
    precondition(parse("HTTPS://MEETING-NOTES.JONABIHL.DEV/meeting/20261105T151700Z/") == plain)
    precondition(parse("meetingnotes://meeting/20261105T151700Z?t=") == plain)
    precondition(parse(base + "x?t=12.25")?.time == 12.25)
    precondition(MeetingLink(meetingID: "x", time: 12.25).string == base + "x?t=12.2")
    for prefix in [base, "meetingnotes://meeting/"] {
      for suffix in [
        "x?t=abc", "x?t=-1", "x?t=nan", "x?t=inf", "", "%20", "a/b",
        "x?p=s1&t=1", "x?p=s1&p=s2", "x?t=1&t=2", "x?p", "x?t", "x?other=1",
        "x#anything", "%00", "%0A", "..%2Foutside", "%2Ftmp%2Frecord",
      ] {
        precondition(parse(prefix + suffix) == nil, "\(prefix + suffix) must be rejected")
      }
    }
    for invalid in [
      "meetingnotes://meeting", "meetingnotes://library/x", "https://meeting/x",
      "http://meeting-notes.jonabihl.dev/meeting/x",
      "https://meeting-notes.jonabihl.dev.evil.example/meeting/x",
      "https://other.jonabihl.dev/meeting/x",
      "https://meeting-notes.jonabihl.dev:443/meeting/x",
      "https://someone@meeting-notes.jonabihl.dev/meeting/x",
      "https://meeting-notes.jonabihl.dev/Meeting/x",
      "https://meeting-notes.jonabihl.dev/start",
      "https://meeting-notes.jonabihl.dev/stop",
      "https://meeting-notes.jonabihl.dev/reveal?id=x",
      base + "/x", base + "x//",
    ] {
      precondition(parse(invalid) == nil, "\(invalid) must be rejected")
      precondition(URLCommand(url: URL(string: invalid)!) == nil)
    }

    let passageLink = parse("meetingnotes://meeting/x?p=s3")!
    precondition(passageLink.passageID == "s3" && passageLink.time == nil)
    precondition(passageLink.string == base + "x?p=s3")
    precondition(parse(passageLink.string) == passageLink)
    for invalid in ["s0", "s-1", "s1x", "", "s999999999999999999999"] {
      precondition(parse(base + "x?p=" + invalid) == nil)
    }

    let segments = [
      MeetingSegment(start: 0.4, end: 20, speaker: "A", text: "one"),
      MeetingSegment(start: 20.1, end: 40, speaker: "B", text: "two"),
      MeetingSegment(start: 20.13, end: 22, speaker: "A", text: "overlap"),
      MeetingSegment(start: 40.75, end: 61.2, speaker: "B", text: "three"),
    ]
    for (index, segment) in segments.enumerated() where index != 2 {
      let link = MeetingLink(meetingID: "x", segment: segment)
      precondition(MeetingLink.segmentIndex(at: link.time!, in: segments) == index)
      precondition(link.time! <= segment.start)
    }
    precondition(MeetingLink.segmentIndex(at: 20.1, in: segments) == 1, "First of the same tenth")
    precondition(MeetingLink.segmentIndex(at: 20, in: segments) == 0)
    precondition(MeetingLink.segmentIndex(at: 30, in: segments) == 1)
    precondition(MeetingLink.segmentIndex(at: 0, in: segments) == 0)
    precondition(MeetingLink.segmentIndex(at: 500, in: segments) == 3)
    precondition(MeetingLink.segmentIndex(at: 5, in: []) == nil)

    var record = MeetingRecord(
      id: "20261105T151700Z", startedAt: Date(timeIntervalSince1970: 0), status: .complete)
    record.segments = segments
    record.durationSeconds = 61.4
    precondition(record.link == plain)
    precondition(record.link(to: segments[1]).string.hasSuffix("?t=20.1"))
    precondition(!MeetingLink.isPastEnd(62, of: record))
    precondition(MeetingLink.isPastEnd(62.5, of: record))
    record.durationSeconds = nil
    precondition(!MeetingLink.isPastEnd(61.5, of: record))

    let json = try! MeetingLibrary.json(record)
    precondition(json["url"]?.stringValue == plain.string)
    guard case .array(let linked) = json["segments"] else {
      preconditionFailure("The JSON record keeps its segments")
    }
    precondition(
      linked.map { $0["url"]?.stringValue } == segments.map { record.link(to: $0).string })
  }
}

extension Smoke {
  @MainActor
  static func testPausedMeetingLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mn-links-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("audio.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80000)!
    buffer.frameLength = 80000
    for index in 0..<80000 { buffer.floatChannelData![0][index] = 0 }
    do {
      let audio = try AVAudioFile(forWriting: file, settings: format.settings)
      try audio.write(from: buffer)
    }
    var record = MeetingRecord(id: "20261107T090000Z", startedAt: Date(), status: .complete)
    record.durationSeconds = 10
    record.segments = [
      .init(start: 0, end: 5, speaker: "Speaker 1", text: "First"),
      .init(start: 5, end: 10, speaker: "Speaker 2", text: "Second"),
    ]
    let app = AppModel()
    app.meetingsRoot = root
    app.meetings = [record]
    app.audioFiles = [record.id: file]
    let model = LibraryModel(app: app)
    model.reload()
    model.open(MeetingLink(meetingID: record.id, time: 6))
    precondition(model.focus?.segment == 1)
    precondition(model.playback.currentTime == 5 && !model.playback.isPlaying)
    model.playback.seek(to: 2)
    precondition(model.playback.currentTime == 2 && !model.playback.isPlaying)
    app.audioFiles = [:]
    model.reload()
    model.open(MeetingLink(meetingID: record.id, time: 6))
    precondition(model.focus?.segment == 1 && model.notice == nil)
    precondition(model.playback.url == nil && !model.playback.isPlaying)
    model.open(MeetingLink(url: URL(string: record.link.string + "?p=s2")!)!)
    precondition(model.focus?.segment == 1 && !model.playback.isPlaying)
    model.open(record.link)
    precondition(model.selection == record.id && model.focus == nil && !model.playback.isPlaying)
    print("Meeting links: paused audio, seeking stays paused, audio-free passage navigation: OK")
  }
}

import AVFoundation
import Foundation

@main
struct Smoke {
  static func main() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("meeting-notes-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let audioDirectory = temporary.appendingPathComponent("audios")
    let transcriptDirectory = temporary.appendingPathComponent("transcripts")
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: transcriptDirectory, withIntermediateDirectories: false)
    let date = Date(timeIntervalSince1970: 0)
    let stem = MeetingFiles.stem(
      for: date, in: audioDirectory, transcriptDirectory: transcriptDirectory)
    precondition(stem == "19700101T000000Z")
    let existing = audioDirectory.appendingPathComponent(stem + ".mp3")
    FileManager.default.createFile(atPath: existing.path, contents: Data([1]))
    precondition(
      MeetingFiles.stem(
        for: date, in: audioDirectory,
        transcriptDirectory: transcriptDirectory) == stem + "-2")

    let store = try StateStore(directory: temporary)
    let diagnosticDirectory = temporary.appendingPathComponent("logs")
    let logger = AppLog(directory: diagnosticDirectory, maxBytes: 1)
    logger.record("first", "multiline\ndetail")
    logger.record("second")
    let previousLog = try Data(
      contentsOf: diagnosticDirectory.appendingPathComponent("meeting-notes.previous.log"))
    let previousEntry = try JSONSerialization.jsonObject(with: previousLog) as! [String: String]
    precondition(previousEntry["event"] == "first")
    precondition(previousEntry["detail"] == "multiline\ndetail")
    try await MeetingFiles.waitForMP3(existing, attempts: 2, interval: 0)
    let delayed = temporary.appendingPathComponent("delayed.mp3")
    FileManager.default.createFile(atPath: delayed.path, contents: Data())
    let writer = Task {
      try await Task.sleep(nanoseconds: 20_000_000)
      try Data([1, 2, 3]).write(to: delayed)
    }
    try await MeetingFiles.waitForMP3(delayed, attempts: 100, interval: 5_000_000)
    try await writer.value
    let empty = temporary.appendingPathComponent("empty.mp3")
    FileManager.default.createFile(atPath: empty.path, contents: Data())
    do {
      try await MeetingFiles.waitForMP3(empty, attempts: 2, interval: 0)
      preconditionFailure("Empty MP3 must fail validation")
    } catch let error as MeetingError {
      precondition(error.message.contains("size=0 bytes"))
    }
    try store.update { $0.pendingAudio = existing.path }
    let reloaded = try StateStore(directory: temporary)
    precondition(reloaded.state.pendingAudio == existing.path)

    let input = temporary.appendingPathComponent("silence.wav")
    try makeSilence(at: input, seconds: 301)
    let chunker = try AudioChunker(file: input)
    precondition(chunker.chunkCount == 2)
    let first = try chunker.chunk(at: 0, original: input, in: temporary)
    let second = try chunker.chunk(at: 1, original: input, in: temporary)
    let firstFile = try AVAudioFile(forReading: first)
    let secondFile = try AVAudioFile(forReading: second)
    precondition(Int(Double(firstFile.length) / 16_000) == 290)
    precondition(Int(Double(secondFile.length) / 16_000) == 11)
    let meeting = { (mic: [String]) in
      TeamsWindowSnapshot(buttons: [["Leave"], mic])
    }
    precondition(TeamsMuteClassifier.classify([meeting(["Unmute mic"])]) == .muted)
    precondition(TeamsMuteClassifier.classify([meeting(["Mute mic (⇧ ⌘ M)"])]) == .unmuted)
    precondition(
      TeamsMuteClassifier.classify([meeting(["Mute mic", "Unmute mic"])])
        == .unavailable(.ambiguous))
    precondition(
      TeamsMuteClassifier.classify([TeamsWindowSnapshot(buttons: [["Unmute mic"]])])
        == .unavailable(.noMeeting))
    precondition(
      TeamsMuteClassifier.classify([meeting(["Unmute mic"]), meeting(["Mute mic"])])
        == .unavailable(.ambiguous))
    precondition(TeamsMuteState.unavailable(.teamsClosed).obsMicrophoneMuted == false)
    var statusChecks = 0
    let stoppingStates = [true, true, false, true, false, false]
    try await OBSClient.waitUntilStopped(attempts: stoppingStates.count, interval: 0) {
      defer { statusChecks += 1 }
      return stoppingStates[statusChecks]
    }
    precondition(statusChecks == stoppingStates.count)
    do {
      try await OBSClient.waitUntilStopped(attempts: 3, interval: 0) { true }
      preconditionFailure("An active recording must not be treated as a finished MP3")
    } catch let error as MeetingError {
      precondition(error.message.contains("still finishing"))
    }
    print("Local state, UTC names, audio chunking, and Teams mute classification: OK")

    if CommandLine.arguments.contains("--live") {
      let obs = try await OBSClient.connect()
      let recording = try await obs.isRecording()
      let streaming = try await obs.isStreaming()
      obs.close()
      try await FluidVoiceClient().health()
      print("OBS read-only status: recording=\(recording), streaming=\(streaming)")
      print("FluidVoice health: OK")
    }
  }

  private static func makeSilence(at url: URL, seconds: Int) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)
    else {
      throw MeetingError("Could not make silent test audio.")
    }
    buffer.frameLength = 16_000
    for _ in 0..<seconds { try file.write(from: buffer) }
  }
}

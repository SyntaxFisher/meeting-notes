import AVFoundation
import Foundation

final class AudioChunker {
  private let input: AVAudioFile
  private let framesPerChunk: AVAudioFramePosition
  let chunkCount: Int

  init(file: URL) throws {
    input = try AVAudioFile(forReading: file)
    let rate = input.processingFormat.sampleRate
    guard rate > 0, input.length > 0 else {
      throw MeetingError("The recording has no decodable audio.")
    }
    framesPerChunk = AVAudioFramePosition(rate * 290)
    chunkCount = Int((input.length + framesPerChunk - 1) / framesPerChunk)
  }

  func chunk(at index: Int, original: URL, in directory: URL) throws -> URL {
    precondition(index >= 0 && index < chunkCount)
    if chunkCount == 1 { return original }

    let start = AVAudioFramePosition(index) * framesPerChunk
    let remaining = min(framesPerChunk, input.length - start)
    let output = directory.appendingPathComponent(String(format: "chunk-%04d.wav", index + 1))
    let format = input.processingFormat
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: format.channelCount,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: true,
    ]
    try writeFrames(to: output, settings: settings, format: format, start: start, count: remaining)
    return output
  }

  private func writeFrames(
    to output: URL, settings: [String: Any], format: AVAudioFormat,
    start: AVAudioFramePosition, count: AVAudioFramePosition
  ) throws {
    let writer = try AVAudioFile(
      forWriting: output, settings: settings,
      commonFormat: .pcmFormatFloat32, interleaved: false)
    input.framePosition = start
    var remaining = count
    while remaining > 0 {
      try Task.checkCancellation()
      let amount = AVAudioFrameCount(min(remaining, 32_768))
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: amount) else {
        throw MeetingError("Could not allocate an audio chunk.")
      }
      try input.read(into: buffer, frameCount: amount)
      guard buffer.frameLength > 0 else { throw MeetingError("The recording ended unexpectedly.") }
      try writer.write(from: buffer)
      remaining -= AVAudioFramePosition(buffer.frameLength)
    }
  }
}

struct MeetingError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

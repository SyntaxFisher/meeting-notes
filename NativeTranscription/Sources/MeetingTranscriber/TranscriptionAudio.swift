import Foundation

struct TranscriptionAudio {
  static func frameCount(remaining: Int64, sampleRate: Double) -> Int64 {
    let maximum = Int64(30 * sampleRate)
    let minimum = Int64(0.3 * sampleRate)
    if remaining <= maximum + minimum { return remaining }
    return maximum
  }

  static func pad(_ samples: [Float], minimumCount: Int) -> [Float] {
    guard samples.count < minimumCount else { return samples }
    // Silence meets the model minimum without borrowing another speaker's audio.
    return samples + Array(repeating: 0, count: minimumCount - samples.count)
  }
}

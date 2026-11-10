import Foundation

/// Separates the local participant's speech from Teams playback that the microphone picks up
/// acoustically when no headphones are used.
///
/// Both tracks share one host clock. Echo appears in the microphone as a delayed, attenuated copy
/// of the Teams track, so its loudness follows the Teams loudness at a fixed lag and ratio. A
/// microphone frame counts as local speech only if it is clearly louder than that prediction.
/// The estimate uses only frames the microphone actually recorded: while Teams is muted the
/// track holds digital silence, which says nothing about the room and, over a long meeting,
/// would hide the echo of the unmuted minutes.
struct EchoFilter {
  static let frameSeconds = 0.02
  private static let lagFrames = -5...20
  private static let localMargin: Float = 2

  let lagFrames: Int
  let coupling: Float
  private let microphone: [Float]
  private let teams: [Float]
  private let microphoneFloor: Float
  private let teamsThreshold: Float

  /// - Parameters: Per-frame RMS loudness of both tracks on the same timeline.
  init(microphone: [Float], teams: [Float]) {
    self.microphone = microphone
    self.teams = teams
    microphoneFloor = max(1e-4, Self.percentile(microphone.filter { $0 > 0 }, 0.1))
    let teamsThreshold = max(0.002, 0.05 * Self.percentile(teams, 0.95))
    self.teamsThreshold = teamsThreshold
    var best = (lag: 0, correlation: Float(0))
    for lag in Self.lagFrames {
      var pairs: [(Float, Float)] = []
      for t in max(0, lag)..<min(microphone.count, teams.count + lag)
      where teams[t - lag] > teamsThreshold && microphone[t] > 0 {
        pairs.append((log(microphone[t] + 1e-5), log(teams[t - lag] + 1e-5)))
      }
      let correlation = Self.correlation(pairs)
      if pairs.count >= 50, correlation > best.correlation { best = (lag, correlation) }
    }
    lagFrames = best.lag
    guard best.correlation > 0.3 else {
      coupling = 0
      return
    }
    var ratios: [Float] = []
    for t in max(0, best.lag)..<min(microphone.count, teams.count + best.lag)
    where teams[t - best.lag] > teamsThreshold && microphone[t] > microphoneFloor * 3 {
      ratios.append(microphone[t] / teams[t - best.lag])
    }
    coupling = ratios.count >= 50 ? Self.percentile(ratios, 0.5) : 0
  }

  /// Whether Teams played audible sound, delayed by the echo's lag, during a good part of the
  /// time from `start` to `end`: only then can microphone speech there be its echo.
  func isPlaying(start: Double, end: Double) -> Bool {
    let first = max(0, Int(start / Self.frameSeconds))
    let last = Int((end / Self.frameSeconds).rounded(.up))
    guard last > first else { return false }
    let playing = (first..<last).filter { t in
      let source = t - lagFrames
      return source >= 0 && source < teams.count && teams[source] > teamsThreshold
    }.count
    return Double(playing) >= 0.3 * Double(last - first)
  }

  /// Whether the microphone frame contains speech that Teams playback does not explain.
  func isLocal(frame t: Int) -> Bool {
    guard t >= 0, t < microphone.count, microphone[t] > microphoneFloor * 3 else { return false }
    let source = t - lagFrames
    let echo = source >= 0 && source < teams.count ? coupling * teams[source] : 0
    return microphone[t] > Self.localMargin * echo
  }

  /// The parts of a microphone segment that contain local speech. Pauses shorter than 0.3 s
  /// stay inside a range and ranges shorter than 0.25 s are dropped, so double talk keeps the
  /// local words while passages that are only Teams playback disappear.
  func localRanges(start: Double, end: Double) -> [ClosedRange<Double>] {
    guard coupling > 0 else { return [start...end] }
    let first = max(0, Int(start / Self.frameSeconds))
    let last = min(microphone.count, Int((end / Self.frameSeconds).rounded(.up)))
    var runs: [ClosedRange<Int>] = []
    for t in first..<max(first, last) where isLocal(frame: t) {
      if let previous = runs.last, t - previous.upperBound <= 15 {
        runs[runs.count - 1] = previous.lowerBound...t
      } else {
        runs.append(t...t)
      }
    }
    return
      runs
      .filter { $0.count >= 13 }
      .map {
        max(
          start, Double($0.lowerBound) * Self.frameSeconds)...min(
            end, Double($0.upperBound + 1) * Self.frameSeconds)
      }
  }

  static func percentile(_ values: [Float], _ quantile: Double) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * quantile))]
  }

  private static func correlation(_ pairs: [(Float, Float)]) -> Float {
    guard pairs.count > 1 else { return 0 }
    let count = Float(pairs.count)
    let meanX = pairs.reduce(0) { $0 + $1.0 } / count
    let meanY = pairs.reduce(0) { $0 + $1.1 } / count
    var covariance: Float = 0
    var varianceX: Float = 0
    var varianceY: Float = 0
    for (x, y) in pairs {
      covariance += (x - meanX) * (y - meanY)
      varianceX += (x - meanX) * (x - meanX)
      varianceY += (y - meanY) * (y - meanY)
    }
    guard varianceX > 0, varianceY > 0 else { return 0 }
    return covariance / (varianceX * varianceY).squareRoot()
  }
}

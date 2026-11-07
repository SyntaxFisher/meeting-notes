import AVFoundation
import Observation

/// Plays one meeting's audio for the library window.
@MainActor
@Observable
final class AudioPlayback {
  private(set) var url: URL?
  private(set) var isPlaying = false
  private(set) var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var error: String?
  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var timer: Timer?

  func load(_ url: URL?) {
    guard url != self.url else { return }
    stop()
    self.url = url
    player = nil
    error = nil
    currentTime = 0
    duration = 0
    guard let url else { return }
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.prepareToPlay()
      self.player = player
      duration = player.duration
    } catch {
      self.error = "The audio cannot be played: \(error.localizedDescription)"
    }
  }

  func togglePlayback() {
    isPlaying ? pause() : play(from: nil)
  }

  func play(from time: TimeInterval?) {
    guard let player else { return }
    if let time { player.currentTime = min(max(0, time), player.duration) }
    player.play()
    isPlaying = true
    currentTime = player.currentTime
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  func pause() {
    player?.pause()
    isPlaying = false
    timer?.invalidate()
    timer = nil
  }

  func seek(to time: TimeInterval) {
    guard let player else { return }
    player.currentTime = min(max(0, time), player.duration)
    currentTime = player.currentTime
  }

  func skip(by seconds: TimeInterval) {
    seek(to: currentTime + seconds)
  }

  func stop() {
    pause()
    player?.currentTime = 0
    currentTime = 0
  }

  private func tick() {
    guard let player else { return }
    currentTime = player.currentTime
    if !player.isPlaying {
      isPlaying = false
      timer?.invalidate()
      timer = nil
    }
  }
}

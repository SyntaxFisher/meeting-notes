import Foundation

/// Header changes follow wheel input, never layout adjustments or elastic scroll rebound.
final class TranscriptScrollIntent {
  private var headerChanging = false
  private var offset: Double = 0
  private var scrollableHeight: Double = 0
  private var distance: Double = 0
  private var target: Int?

  func observe(offset: Double, height: Double, contentHeight: Double) {
    scrollableHeight = max(0, contentHeight - height)
    self.offset = min(max(0, offset), scrollableHeight)
  }

  func scrollWheel(delta: Double, began: Bool, compact: Bool) -> Bool? {
    cancelTarget()
    guard delta != 0 else { return nil }
    if began || (delta > 0) != (distance > 0) { distance = 0 }
    guard !headerChanging else { return nil }
    distance += delta
    let up = delta > 0
    guard compact == up else { return nil }
    if up {
      guard offset <= 48 || distance >= 48 else { return nil }
    } else {
      guard scrollableHeight >= 48, distance <= -48 else { return nil }
    }
    headerChanging = true
    distance = 0
    return !up
  }

  func headerSettled() {
    headerChanging = false
    distance = 0
  }

  func cancelTarget() { target = nil }

  func shouldScroll(to segment: Int, force: Bool = false) -> Bool {
    guard force || target != segment else { return false }
    target = segment
    return true
  }
}

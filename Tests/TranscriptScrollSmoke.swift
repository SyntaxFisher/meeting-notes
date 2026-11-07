import Foundation

enum TranscriptScrollSmoke {
  static func run() {
    let intent = TranscriptScrollIntent()
    intent.observe(offset: 0, height: 500, contentHeight: 2_000)
    precondition(intent.scrollWheel(delta: -24, began: true, compact: false) == nil)
    precondition(intent.scrollWheel(delta: -24, began: false, compact: false) == true)
    intent.observe(offset: 0, height: 580, contentHeight: 2_000)
    precondition(intent.scrollWheel(delta: 60, began: false, compact: true) == nil)
    intent.headerSettled()

    // Bottom overshoot and rebound can change offsets without changing the user's direction.
    for offset in [1_420.0, 1_480, 1_450, 1_420, 1_400, 1_420] {
      intent.observe(offset: offset, height: 580, contentHeight: 2_000)
      precondition(intent.scrollWheel(delta: -60, began: false, compact: true) == nil)
    }
    precondition(intent.scrollWheel(delta: 24, began: true, compact: true) == nil)
    precondition(intent.scrollWheel(delta: 24, began: false, compact: true) == false)
    intent.headerSettled()

    // Top overshoot, rebound and viewport changes must not collapse the expanded header.
    for offset in [0.0, -80, -40, 0, 20, 0] {
      intent.observe(offset: offset, height: 500, contentHeight: 2_000)
      precondition(intent.scrollWheel(delta: 60, began: false, compact: false) == nil)
    }
    precondition(intent.scrollWheel(delta: -24, began: true, compact: false) == nil)
    precondition(intent.scrollWheel(delta: -24, began: false, compact: false) == true)
    intent.headerSettled()
    intent.observe(offset: 10, height: 580, contentHeight: 2_000)
    precondition(intent.scrollWheel(delta: 1, began: true, compact: true) == false)
    intent.headerSettled()

    let short = TranscriptScrollIntent()
    short.observe(offset: 0, height: 500, contentHeight: 200)
    precondition(short.scrollWheel(delta: -200, began: true, compact: false) == nil)
    short.observe(offset: -100, height: 500, contentHeight: 200)
    precondition(short.scrollWheel(delta: 200, began: true, compact: false) == nil)

    precondition(intent.shouldScroll(to: 7))
    precondition(!intent.shouldScroll(to: 7))
    precondition(intent.shouldScroll(to: 7, force: true))
    intent.cancelTarget()
    precondition(intent.shouldScroll(to: 7))
    print(
      "Transcript scrolling: stable headers at both edges, short content and explicit jumps: OK")
  }
}

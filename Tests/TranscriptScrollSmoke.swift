import AppKit

enum TranscriptScrollSmoke {
  @MainActor
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
    rowLayout()
  }

  @MainActor
  private static func rowLayout() {
    let metrics = TranscriptRowMetrics(
      width: 600, timestampWidth: 60, nameHeight: 15, heights: [40, 100, 60])
    precondition(metrics.tops == [0, 54, 168] && metrics.totalHeight == 228)
    precondition(metrics.rows(from: 0, to: 1) == 0..<1)
    precondition(metrics.rows(from: 45, to: 160) == 1..<2, "the spacing belongs to no row")
    precondition(metrics.rows(from: 30, to: 170) == 0..<3)
    precondition(metrics.rows(from: 300, to: 400).isEmpty)
    precondition(
      metrics.row(at: 47) == nil && metrics.row(at: 54) == 1 && metrics.row(at: 227) == 2)
    // Spacers around the shown rows add up to the full height, so showing other rows never
    // changes the document height.
    for shown in [0..<1, 1..<2, 0..<3, 2..<3] {
      let rows = shown.map { metrics.heights[$0] }.reduce(0, +)
      let spacing = CGFloat(shown.count - 1) * TranscriptRowMetrics.spacing
      precondition(
        metrics.space(before: shown) + rows + spacing + metrics.space(after: shown)
          == metrics.totalHeight)
    }

    // Rows are rebuilt in batches: scrolling within the margin keeps them.
    let shown = TranscriptViewport.realized(current: 0..<12, visible: 2..<6, count: 500)
    precondition(shown == 0..<12)
    let moved = TranscriptViewport.realized(current: shown, visible: 9..<14, count: 500)
    precondition(moved == 0..<26)
    precondition(TranscriptViewport.realized(current: moved, visible: 10..<15, count: 500) == moved)
    precondition(
      TranscriptViewport.realized(current: moved, visible: 495..<500, count: 500) == 483..<500)

    // A passage measured for its row lays out to the same height in the text view that shows it.
    let text = String(repeating: "Wir starten mit dem Kapitel 5, Integralrechnung. ", count: 9)
    for width in [180.0, 333.5, 640] {
      let view = NSTextView(usingTextLayoutManager: false)
      view.textContainerInset = .zero
      view.textContainer?.lineFragmentPadding = 0
      view.textContainer?.widthTracksTextView = true
      view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
      view.textStorage?.setAttributedString(
        NSAttributedString(string: text, attributes: TranscriptText.attributes))
      guard let layout = view.layoutManager, let container = view.textContainer else { return }
      layout.ensureLayout(for: container)
      precondition(
        ceil(layout.usedRect(for: container).height)
          == TranscriptText.height(of: text, width: width))
    }
    print("Transcript rows: exact positions, constant document height and batched rows: OK")
  }
}

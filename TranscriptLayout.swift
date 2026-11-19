import AppKit
import Observation

/// Transcript passages are laid out and measured with the same TextKit 1 setup, so a passage's
/// row height is known before the passage is ever shown.
@MainActor
enum TranscriptText {
  static let attributes: [NSAttributedString.Key: Any] = {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    return [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
  }()

  private static let storage = NSTextStorage()
  private static let container: NSTextContainer = {
    let container = NSTextContainer()
    container.lineFragmentPadding = 0
    let layout = NSLayoutManager()
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    return container
  }()

  private struct Key: Hashable {
    let text: String
    let width: CGFloat
  }
  private static var heights: [Key: CGFloat] = [:]

  /// Cached, since SwiftUI measures shown passages again on every layout pass.
  static func height(of text: String, width: CGFloat) -> CGFloat {
    let key = Key(text: text, width: width)
    if let height = heights[key] { return height }
    let container = self.container
    guard let layout = container.layoutManager else { return 0 }
    container.size = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
    storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    layout.ensureLayout(for: container)
    let height = ceil(layout.usedRect(for: container).height)
    if heights.count > 20_000 { heights.removeAll(keepingCapacity: true) }
    heights[key] = height
    return height
  }
}

/// Exact heights and positions of every transcript row for one content width. Rows are fixed to
/// these heights, so the document height never changes while scrolling and rows can be shown on
/// demand.
struct TranscriptRowMetrics: Equatable {
  static let spacing: CGFloat = 14
  static let horizontalPadding: CGFloat = 10
  static let verticalPadding: CGFloat = 6
  static let columnSpacing: CGFloat = 14
  static let nameSpacing: CGFloat = 3

  let width: CGFloat
  let timestampWidth: CGFloat
  let nameHeight: CGFloat
  let heights: [CGFloat]
  /// Each row's top, measured from the first row's top.
  let tops: [CGFloat]

  @MainActor
  init(turns: [TranscriptTurn], width: CGFloat) {
    let calloutSize = NSFont.preferredFont(forTextStyle: .callout).pointSize
    let timestampFont = NSFont.monospacedDigitSystemFont(ofSize: calloutSize, weight: .regular)
    let widest = turns.map(\.timestamp).max { $0.count < $1.count } ?? ""
    let timestampWidth =
      ceil((widest as NSString).size(withAttributes: [.font: timestampFont]).width) + 2
    let nameHeight = ceil(
      NSLayoutManager().defaultLineHeight(
        for: NSFont.systemFont(ofSize: calloutSize, weight: .semibold)))
    let textWidth = width - 2 * Self.horizontalPadding - timestampWidth - Self.columnSpacing
    let chrome = 2 * Self.verticalPadding + nameHeight + Self.nameSpacing
    self.init(
      width: width, timestampWidth: timestampWidth, nameHeight: nameHeight,
      heights: turns.map { chrome + TranscriptText.height(of: $0.text, width: textWidth) })
  }

  init(width: CGFloat, timestampWidth: CGFloat, nameHeight: CGFloat, heights: [CGFloat]) {
    self.width = width
    self.timestampWidth = timestampWidth
    self.nameHeight = nameHeight
    self.heights = heights
    var top: CGFloat = 0
    tops = heights.map { height in
      defer { top += height + Self.spacing }
      return top
    }
  }

  var totalHeight: CGFloat { (tops.last ?? 0) + (heights.last ?? 0) }

  /// The space the rows before `shown` take, including the spacing to the first shown row.
  func space(before shown: Range<Int>) -> CGFloat {
    shown.isEmpty ? totalHeight : tops[shown.lowerBound]
  }

  /// The space the rows after `shown` take, including the spacing after the last shown row.
  func space(after shown: Range<Int>) -> CGFloat {
    guard let last = shown.last else { return 0 }
    return totalHeight - tops[last] - heights[last]
  }

  /// The row at `y` in the first row's coordinates; none in the spacing between rows.
  func row(at y: CGFloat) -> Int? {
    let candidates = rows(from: y, to: y + 0.5)
    guard let row = candidates.first, tops[row] <= y else { return nil }
    return row
  }

  /// The rows that intersect the span `from..<to`, in the first row's coordinates.
  func rows(from: CGFloat, to: CGFloat) -> Range<Int> {
    guard !heights.isEmpty, to > from else { return 0..<0 }
    // The first row whose bottom lies below `from`, and the first row starting at or after `to`.
    let first = partition { tops[$0] + heights[$0] > from }
    let end = partition { tops[$0] >= to }
    return first..<max(first, end)
  }

  private func partition(_ isAfter: (Int) -> Bool) -> Int {
    var low = 0
    var high = tops.count
    while low < high {
      let middle = (low + high) / 2
      if isAfter(middle) { high = middle } else { low = middle + 1 }
    }
    return low
  }
}

/// Which transcript rows exist as views. Only rows near the visible ones are built, so scrolling
/// costs the same for any transcript length; the rest are empty space of their exact height.
@MainActor
@Observable
final class TranscriptViewport {
  nonisolated static let margin = 4
  nonisolated static let overscan = 12

  /// The rows on screen; read by views that react to them, never by the transcript itself.
  private(set) var visibleRows: Range<Int> = 0..<0
  private(set) var realized: Range<Int> = 0..<overscan
  /// The row under the pointer. One hover region for all rows keeps scrolling from hit-testing
  /// every row on each frame.
  private(set) var hoveredRow: Int?
  /// An offset that keeps the passage at the top in place after the row heights changed, for
  /// example when the window was resized.
  private(set) var anchoredOffset: AnchoredOffset?

  struct AnchoredOffset: Equatable {
    let offset: CGFloat
    let id = UUID()
  }
  var width: CGFloat?
  nonisolated static let contentSpace = "transcript-content"

  /// How much of the viewport's top the meeting header covers.
  @ObservationIgnored var topInset: CGFloat = 0
  /// Where the first row starts in the scroll content, below any status card.
  @ObservationIgnored private var rowsOrigin: CGFloat = 0
  @ObservationIgnored private var cached: (turns: [TranscriptTurn], metrics: TranscriptRowMetrics)?
  @ObservationIgnored private var scrollSpan: (offset: CGFloat, height: CGFloat)?
  @ObservationIgnored private var contentHeight: CGFloat = 0
  /// Where a programmatic scroll is heading, until the scroll view arrives there.
  @ObservationIgnored private var scrollTarget: CGFloat?

  func metrics(for turns: [TranscriptTurn]) -> TranscriptRowMetrics? {
    guard let width, width > 0 else { return nil }
    if let cached, cached.metrics.width == width, cached.turns == turns { return cached.metrics }
    let metrics = TranscriptRowMetrics(turns: turns, width: width)
    let anchor = topAnchor()
    cached = (turns, metrics)
    // Called while SwiftUI evaluates the transcript, which must not change the rows it reads.
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let anchor, let offset = self.offset(of: anchor.row, fraction: anchor.fraction),
        offset != self.scrollSpan?.offset
      {
        self.anchoredOffset = AnchoredOffset(offset: offset)
      }
      self.refresh()
    }
    return metrics
  }

  /// The passage at the top of the viewport and how far it is scrolled past, before the rows
  /// change.
  private func topAnchor() -> (row: Int, fraction: CGFloat)? {
    guard let metrics = cached?.metrics, let scrollSpan else { return nil }
    let y = scrollSpan.offset + topInset - rowsOrigin
    guard y > 0, let row = metrics.rows(from: y, to: y + 1).first else { return nil }
    let span = metrics.heights[row] + TranscriptRowMetrics.spacing
    return (row, min(1, max(0, (y - metrics.tops[row]) / span)))
  }

  /// The scroll offset that shows a row right below the header, or that part of it given by
  /// `fraction`.
  func offset(of row: Int, fraction: CGFloat = 0) -> CGFloat? {
    guard let metrics = cached?.metrics, metrics.tops.indices.contains(row) else { return nil }
    let span = metrics.heights[row] + TranscriptRowMetrics.spacing
    return max(0, rowsOrigin + metrics.tops[row] + fraction * span - topInset)
  }

  /// Starts waiting for the scroll view to reach `offset`, as far as it can scroll; true when it
  /// is there already.
  func beginScroll(to offset: CGFloat) -> Bool {
    let reachable = min(offset, max(0, contentHeight - (scrollSpan?.height ?? 0)))
    scrollTarget = reachable
    return reachedScrollTarget
  }

  var reachedScrollTarget: Bool {
    guard let scrollTarget, let scrollSpan else { return false }
    return abs(scrollSpan.offset - scrollTarget) < 1
  }

  func endScroll() { scrollTarget = nil }

  func hover(at y: CGFloat?) {
    let row = y.flatMap { cached?.metrics.row(at: $0) }
    if row != hoveredRow { hoveredRow = row }
  }

  func setRowsOrigin(_ origin: CGFloat) {
    guard origin != rowsOrigin else { return }
    rowsOrigin = origin
    refresh()
  }

  private func refresh() {
    if let scrollSpan { scrolled(offset: scrollSpan.offset, height: scrollSpan.height) }
  }

  func scrolled(offset: CGFloat, height: CGFloat, contentHeight: CGFloat) {
    self.contentHeight = contentHeight
    scrolled(offset: offset, height: height)
  }

  private func scrolled(offset: CGFloat, height: CGFloat) {
    scrollSpan = (offset, height)
    guard let metrics = cached?.metrics else { return }
    let visible = metrics.rows(
      from: offset + topInset - rowsOrigin, to: offset + height - rowsOrigin)
    if visible != visibleRows { visibleRows = visible }
    let next = Self.realized(current: realized, visible: visible, count: metrics.heights.count)
    if next != realized { realized = next }
  }

  /// Keeps the current rows while the visible ones stay well inside them, so rows are rebuilt in
  /// batches rather than on every passage scrolled past.
  nonisolated static func realized(current: Range<Int>, visible: Range<Int>, count: Int)
    -> Range<Int>
  {
    guard !visible.isEmpty else { return current }
    let needed = max(0, visible.lowerBound - margin)..<min(count, visible.upperBound + margin)
    if current.lowerBound <= needed.lowerBound, current.upperBound >= needed.upperBound {
      return current
    }
    return max(0, visible.lowerBound - overscan)..<min(count, visible.upperBound + overscan)
  }
}

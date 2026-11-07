import AppKit
import SwiftUI

struct TranscriptScrollWheel: NSViewRepresentable {
  let scrolled: (Double, Bool) -> Void

  func makeNSView(context: Context) -> Observer {
    let view = Observer()
    view.scrolled = scrolled
    return view
  }

  func updateNSView(_ view: Observer, context: Context) { view.scrolled = scrolled }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Observer, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }

  final class Observer: NSView {
    var scrolled: ((Double, Bool) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, let window = self.window, window.isKeyWindow,
          event.momentumPhase.isEmpty,
          self.bounds.contains(
            self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)),
          event.scrollingDeltaY != 0
        else { return event }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        self.scrolled?(delta, event.phase.contains(.began))
        return event
      }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

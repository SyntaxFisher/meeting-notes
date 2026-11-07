import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A popover-like panel below the status item. When the notch or a crowded menu bar hides the
/// item, the panel opens at the top-right corner of the screen instead.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
  private let panel: KeyablePanel
  private weak var statusButton: NSStatusBarButton?
  private var lastClosed = Date.distantPast
  private var outsideClickMonitor: Any?
  var onVisibilityChanged: ((Bool) -> Void)?
  var isVisible: Bool { panel.isVisible }

  init(model: AppModel, statusButton: NSStatusBarButton?) {
    self.statusButton = statusButton
    panel = KeyablePanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: true)
    super.init()
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hasShadow = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
    panel.delegate = self
    panel.setAccessibilityLabel("Meeting Notes")
    panel.setAccessibilityIdentifier("meeting-notes-panel")
    panel.onCancel = { [weak self] in self?.close() }

    let hosting = NSHostingController(
      rootView: PanelView(model: model)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
    hosting.sizingOptions = [.preferredContentSize]
    hosting.view.wantsLayer = true
    hosting.view.layer?.backgroundColor = .clear
    panel.contentViewController = hosting
  }

  func toggle() {
    // A click on the status item first closes the panel by taking key focus away.
    if panel.isVisible || Date().timeIntervalSince(lastClosed) < 0.3 {
      close()
    } else {
      show()
    }
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    panel.layoutIfNeeded()
    position()
    panel.makeKeyAndOrderFront(nil)
    AppLog.event("panel.shown", visibleStatusItemFrame() == nil ? "screenCorner" : "statusItem")
    if outsideClickMonitor == nil {
      outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
        .leftMouseDown, .rightMouseDown,
      ]) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      }
    }
    onVisibilityChanged?(true)
  }

  func close() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
    lastClosed = Date()
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    outsideClickMonitor = nil
    onVisibilityChanged?(false)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard NSApp.modalWindow == nil else { return }
    close()
  }

  func windowDidResize(_ notification: Notification) {
    guard panel.isVisible, !positioning else { return }
    position()
    panel.invalidateShadow()
  }

  private var positioning = false

  private func position() {
    positioning = true
    defer { positioning = false }
    var size = panel.contentViewController?.preferredContentSize ?? .zero
    if size.width < 1 || size.height < 1 {
      size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
    }
    size = NSSize(width: ceil(size.width), height: ceil(size.height))
    let anchor = visibleStatusItemFrame()
    let screen =
      anchor.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
      ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    var origin: NSPoint
    if let anchor {
      origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
    } else {
      origin = NSPoint(x: visible.maxX - size.width - 10, y: visible.maxY - size.height - 6)
    }
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
    origin.y = max(origin.y, visible.minY + 8)
    let frame = NSRect(origin: origin, size: size)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }

  /// The status item's frame on screen, or nil when the notch or overflow hides it.
  private func visibleStatusItemFrame() -> NSRect? {
    guard let button = statusButton, let window = button.window, window.isVisible,
      window.occlusionState.contains(.visible)
    else { return nil }
    let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
      return nil
    }
    guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
    else { return frame }
    let leftArea = left.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    let rightArea = right.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    let unobscured =
      (frame.minX >= leftArea.minX && frame.maxX <= leftArea.maxX)
      || (frame.minX >= rightArea.minX && frame.maxX <= rightArea.maxX)
    return unobscured ? frame : nil
  }
}

struct VisualEffectBackground: NSViewRepresentable {
  var material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.state = .active
    view.blendingMode = .behindWindow
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

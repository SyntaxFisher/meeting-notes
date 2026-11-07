import AppKit
import SwiftUI

struct SelectableTranscriptText: NSViewRepresentable {
  let text: String
  let jump: (() -> Void)?
  let edit: (() -> Void)?

  func makeNSView(context: Context) -> TextView {
    let view = TextView()
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = true
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: TextView, context: Context) {
    view.jump = jump
    view.edit = edit
    guard view.string != text else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    view.textStorage?.setAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
          .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
    guard let width = proposal.width, let container = nsView.textContainer,
      let layout = nsView.layoutManager
    else { return nil }
    container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
  }

  final class TextView: NSTextView {
    var jump: (() -> Void)?
    var edit: (() -> Void)?

    // The transcript owns scrolling; AppKit's text selection must not reposition its rows.
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func mouseDown(with event: NSEvent) {
      let action = jump
      let start = NSEvent.mouseLocation
      super.mouseDown(with: event)
      let end = NSEvent.mouseLocation
      guard event.clickCount == 1, selectedRange().length == 0,
        hypot(end.x - start.x, end.y - start.y) <= 3
      else { return }
      action?()
    }

    override func rightMouseDown(with event: NSEvent) {
      guard let menu = menu(for: event) else { return }
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      if selectedRange().length > 0 {
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
      }
      for (title, action) in [
        ("Copy Passage", #selector(copyPassage)),
        ("Edit Text…", #selector(editPassage)), ("Jump to Here", #selector(jumpToPassage)),
      ] {
        if action == #selector(editPassage), edit == nil { continue }
        if action == #selector(jumpToPassage), jump == nil { continue }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
      }
      return menu
    }

    @objc private func copyPassage() {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    }

    @objc private func editPassage() { edit?() }
    @objc private func jumpToPassage() { jump?() }
  }
}

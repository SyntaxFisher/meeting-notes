import AppKit
import SwiftUI

enum MeetingDetailField: Equatable, Sendable {
  case title, summary

  var label: String { self == .title ? "Meeting title" : "Description" }
  var actionName: String { self == .title ? "Rename Meeting" : "Edit Description" }

  func value(in record: MeetingRecord) -> MeetingDetailValue {
    switch self {
    case .title: .title(record.title, record.titleSource)
    case .summary: .summary(record.summary)
    }
  }

  func value(_ text: String, replacing record: MeetingRecord) -> MeetingDetailValue {
    switch self {
    case .title:
      let title = MeetingFiles.displayTitle(text)
      return .title(
        title, title == record.title ? record.titleSource : title == nil ? .none : .user)
    case .summary:
      let summary = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      return .summary(summary.isEmpty ? nil : summary)
    }
  }
}

enum MeetingDetailValue: Equatable, Sendable {
  case title(String?, MeetingTitleSource)
  case summary(String?)

  var text: String {
    switch self {
    case .title(let text, _), .summary(let text): text ?? ""
    }
  }
}

struct EditableMeetingText: View {
  let model: LibraryModel
  let record: MeetingRecord
  let field: MeetingDetailField
  var compact = false
  @State private var editingRecord: MeetingRecord?
  @State private var draft = ""
  @State private var saving = false
  @State private var error: String?

  private var text: String { field.value(in: record).text }
  private var displayText: String {
    field == .title ? record.displayTitle : text.isEmpty ? "Add description..." : text
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if editingRecord != nil {
        MeetingDetailsInput(
          text: $draft, field: field, compact: compact, commit: save, cancel: cancel
        )
        .disabled(saving)
        .onChange(of: draft) { _, _ in error = nil }
        .background(EditingBoundary(commit: save))
        if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
      } else {
        Text(displayText)
          .foregroundStyle(field == .title ? .primary : .secondary)
          .lineLimit(compact ? 1 : nil)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture(count: 2, perform: beginEditing)
          .help(field == .title ? "Double-click to rename" : "Double-click to edit description")
          .accessibilityAddTraits(field == .title ? .isHeader : [])
          .accessibilityAction(named: field.actionName, beginEditing)
          .accessibilityIdentifier(field == .title ? "meeting-title" : "meeting-description")
      }
    }
    .font(field == .title ? compact ? .headline : .title.weight(.semibold) : .body)
    .onDisappear(perform: save)
  }

  private func beginEditing() {
    guard !record.status.isInProgress,
      field == .title || record.status == .complete && !record.segments.isEmpty
    else { return }
    editingRecord = record
    draft = text
    error = nil
  }

  private func cancel() {
    guard !saving else { return }
    editingRecord = nil
    error = nil
  }

  private func save() {
    guard let editingRecord, !saving, error == nil else { return }
    saving = true
    let text = draft
    Task {
      do {
        _ = try await model.saveDetail(text, field: field, for: editingRecord)
        self.editingRecord = nil
      } catch {
        if let latest = try? await model.latestRecord(editingRecord.id) {
          self.editingRecord = latest
          self.error =
            error.localizedDescription + " Current value: " + field.value(in: latest).text
        } else {
          self.error = error.localizedDescription
        }
      }
      saving = false
    }
  }
}

private struct MeetingDetailsInput: NSViewRepresentable {
  @Binding var text: String
  let field: MeetingDetailField
  let compact: Bool
  let commit: () -> Void
  let cancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> MeetingDetailsTextField {
    let input = MeetingDetailsTextField()
    input.isEditable = true
    input.isSelectable = true
    input.isBezeled = true
    input.bezelStyle = .roundedBezel
    input.cell?.wraps = true
    input.cell?.isScrollable = false
    input.maximumNumberOfLines = 0
    input.delegate = context.coordinator
    input.setAccessibilityLabel(field.label)
    input.identifier = NSUserInterfaceItemIdentifier(
      field == .title ? "meeting-title-input" : "meeting-description-input")
    return input
  }

  func updateNSView(_ input: MeetingDetailsTextField, context: Context) {
    context.coordinator.parent = self
    if input.stringValue != text { input.stringValue = text }
    input.font =
      field == .title
      ? .systemFont(ofSize: compact ? 13 : 22, weight: .semibold) : .systemFont(ofSize: 13)
    input.isEnabled = context.environment.isEnabled
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeetingDetailsTextField, context: Context)
    -> CGSize?
  {
    let width = proposal.width ?? 300
    let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000))
    return CGSize(width: width, height: max(field == .title ? 32 : 24, size?.height ?? 24))
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: MeetingDetailsInput
    init(_ parent: MeetingDetailsInput) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let input = notification.object as? NSTextField else { return }
      parent.text = input.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) { parent.commit() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      parent.cancel()
      return true
    }
  }
}

final class MeetingDetailsTextField: NSTextField {
  let editor: MeetingDetailsFieldEditor = {
    let editor = MeetingDetailsFieldEditor()
    editor.isFieldEditor = true
    editor.allowsUndo = true
    return editor
  }()

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self)
      self.currentEditor()?.selectAll(nil)
    }
  }
}

/// Draft typing and committed meeting edits have separate undo stacks.
final class MeetingDetailsFieldEditor: NSTextView {
  private let typingUndoManager = UndoManager()
  override var undoManager: UndoManager? { typingUndoManager }
}

/// Nonfocusable content must also commit an edit when clicked.
private struct EditingBoundary: NSViewRepresentable {
  var commit: () -> Void

  func makeNSView(context: Context) -> Boundary { Boundary() }
  func updateNSView(_ view: Boundary, context: Context) { view.commit = commit }
  static func dismantleNSView(_ view: Boundary, coordinator: ()) { view.stop() }

  final class Boundary: NSView {
    var commit: () -> Void = {}
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard let window else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, event.window === self.window else { return event }
        if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.commit() }
        return event
      }
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.commit() }
          })
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
    }
  }
}

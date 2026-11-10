import AppKit

enum MeetingDetailsSmoke {
  @MainActor
  static func run() async throws {
    let input = MeetingDetailsTextField()
    precondition(input.editor.textStorage != nil && input.editor.textContainer != nil)
    let typingUndo = input.editor.undoManager!
    typingUndo.groupsByEvent = false
    typingUndo.beginUndoGrouping()
    input.editor.insertText("Draft", replacementRange: NSRange(location: 0, length: 0))
    typingUndo.endUndoGrouping()
    precondition(input.editor.string == "Draft" && typingUndo.canUndo)
    typingUndo.undo()
    precondition(input.editor.string.isEmpty)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mn-details-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (library, original) = try TranscriptEditsSmoke.fixture(root)
    let app = AppModel()
    app.meetingsRoot = root
    app.meetings = [original]
    let model = LibraryModel(app: app)
    model.reload()
    model.undoManager.groupsByEvent = false

    let named = try await model.saveDetail("Release planning", field: .title, for: original)
    precondition(named.title == "Release planning" && named.titleSource == .user)
    let described = try await model.saveDetail(
      "  We discussed the launch.  ", field: .summary, for: original)
    precondition(described.title == named.title && described.summary == "We discussed the launch.")
    model.undoManager.undo()
    await model.waitForDetailChanges()
    var current = try library.load(original.id)
    precondition(current.summary == nil && current.title == named.title)
    model.undoManager.undo()
    await model.waitForDetailChanges()
    current = try library.load(original.id)
    precondition(current.title == original.title && current.titleSource == original.titleSource)
    model.undoManager.redo()
    model.undoManager.redo()
    await model.waitForDetailChanges()
    current = try library.load(original.id)
    precondition(current.title == named.title && current.summary == described.summary)

    let cleared = try await model.saveDetail(" \n", field: .summary, for: current)
    precondition(cleared.summary == nil)
    model.undoManager.undo()
    await model.waitForDetailChanges()
    current = try library.load(original.id)
    precondition(current.summary == described.summary)
    let unchanged = try await model.saveDetail(current.title!, field: .title, for: current)
    precondition(unchanged.revision == current.revision)

    _ = try library.updateMeeting(original.id, summary: "Changed by another editor.")
    do {
      _ = try await model.saveDetail("Stale draft", field: .summary, for: current)
      preconditionFailure("A stale description must not overwrite a concurrent edit")
    } catch { precondition(error.localizedDescription.contains("changed elsewhere")) }
    precondition(try! library.load(original.id).summary == "Changed by another editor.")
    do {
      _ = try await model.saveDetail(
        String(repeating: "x", count: 1001), field: .summary,
        for: library.load(original.id))
      preconditionFailure("Descriptions must respect the storage limit")
    } catch { precondition(error.localizedDescription.contains("1,000")) }
    precondition(try! Data(contentsOf: library.audioURL(of: original)!) == Data([1, 2, 3, 4]))
    precondition(try! library.load(original.id).segments == original.segments)
    print(
      "Meeting details: independent inline edits, clearing, undo/redo, provenance and conflicts: OK"
    )
  }

  @MainActor
  static func showFixture(root: URL) throws {
    let application = NSApplication.shared
    let (library, record) = try TranscriptEditsSmoke.fixture(root)
    let app = AppModel()
    app.meetingsRoot = root
    app.meetings = [record]
    app.folderAccess = .granted
    let model = LibraryModel(app: app)
    app.send = { command in
      if case .refreshLibrary = command {
        app.meetings = library.meetings()
        model.reload()
      }
    }
    let window = LibraryWindowController(model: model)
    DispatchQueue.main.async { window.show(selecting: record.id) }
    withExtendedLifetime(window) { application.run() }
  }
}

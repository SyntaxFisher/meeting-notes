import AppKit
import UniformTypeIdentifiers

extension DiagnosticsExport {
  /// Asks where to save a meeting's diagnostics zip, writes it in the background and shows it
  /// in the Finder. Returns false when the save dialog was cancelled; `started` runs once the
  /// zip is being written.
  @MainActor
  @discardableResult
  static func exportWithSavePanel(
    _ record: MeetingRecord, root: URL, started: () -> Void = {}
  ) async throws -> Bool {
    let panel = NSSavePanel()
    panel.title = "Export Diagnostics"
    panel.message =
      "The zip file contains this meeting's transcript, participant names, Teams trace, logs "
      + "and, if included, its audio. Share it only with people who may hear the meeting."
    let audio = NSButton(checkboxWithTitle: "Include audio", target: nil, action: nil)
    audio.state = .on
    audio.toolTip =
      "Replaying the transcription needs the audio. Without it, the zip is much smaller."
    let split = NSButton(checkboxWithTitle: "Split into chunks", target: nil, action: nil)
    let accessory = NSStackView(views: [audio, split])
    accessory.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
    panel.accessoryView = accessory
    panel.nameFieldStringValue = fileName(for: record.id)
    panel.allowedContentTypes = [.zip]
    panel.directoryURL =
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
      .first
    NSApp.activate()
    guard panel.runModal() == .OK, let destination = panel.url else { return false }
    let includesAudio = audio.state == .on
    let splitsIntoParts = split.state == .on
    started()
    let id = record.id
    _ = try await Task.detached(priority: .userInitiated) {
      var export = DiagnosticsExport(library: MeetingLibrary(root: root))
      export.includesAudio = includesAudio
      export.splitsIntoParts = splitsIntoParts
      return try export.write(id, to: destination, replacing: true)
    }.value
    let parts = parts(of: destination)
    NSWorkspace.shared.activateFileViewerSelecting(parts.isEmpty ? [destination] : parts)
    return true
  }
}

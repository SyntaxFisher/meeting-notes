import AppKit
import Observation
import SwiftUI

struct TranscriptTurn: Identifiable, Equatable {
  static func rowID(_ segment: Int) -> String { "segment-\(segment)" }

  let id: Int
  let start: TimeInterval
  let timestamp: String
  let speaker: String
  let text: String
}

/// The transcript segment a meeting link pointed to: scrolled into view and highlighted while
/// its meeting stays selected. Each opened link is a new focus, so the same link scrolls again.
struct TranscriptFocus: Equatable {
  let meetingID: String
  let segment: Int
  let id = UUID()
}

enum LibraryEditor: Identifiable {
  case transcript(MeetingRecord, segment: Int)
  case speakers(MeetingRecord)

  var id: String {
    switch self {
    case .transcript(let record, let segment): "text-\(record.id)-\(segment)"
    case .speakers(let record): "speakers-\(record.id)"
    }
  }
}

@MainActor
@Observable
final class LibraryModel {
  let app: AppModel
  let playback = AudioPlayback()
  private(set) var records: [MeetingRecord] = []
  var selection: String? {
    didSet { if selection != oldValue { selectionChanged() } }
  }
  var searchText = ""
  var searchFocused = false
  var editor: LibraryEditor?
  var pendingDeletion: MeetingRecord?
  var errorMessage: String?
  private(set) var focus: TranscriptFocus?
  /// A short message that hides by itself, for example why a link could not be followed.
  private(set) var notice: String?
  @ObservationIgnored private(set) var library: MeetingLibrary
  @ObservationIgnored private var followedRecording: String?
  @ObservationIgnored private var noticeTask: Task<Void, Never>?

  init(app: AppModel) {
    self.app = app
    library = MeetingLibrary(root: app.meetingsRoot)
  }

  var selectedRecord: MeetingRecord? { records.first { $0.id == selection } }

  struct Group: Identifiable {
    let id: String
    let title: String
    let records: [MeetingRecord]
  }

  var groups: [Group] {
    let visible = records.filter { library.matches($0, query: searchText) }
    var groups: [Group] = []
    let active = visible.filter(\.status.isInProgress)
    if !active.isEmpty { groups.append(Group(id: "active", title: "In Progress", records: active)) }
    let attention = visible.filter(\.status.needsAttention)
    if !attention.isEmpty {
      groups.append(Group(id: "attention", title: "Needs Attention", records: attention))
    }
    let finished = visible.filter { $0.status == .complete }
    for day in MeetingLibrary.groupedByDay(finished) {
      groups.append(
        Group(id: day.day.ISO8601Format(), title: Self.dayTitle(day.day), records: day.records))
    }
    return groups
  }

  static func dayTitle(_ day: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(day) { return "Today" }
    if calendar.isDateInYesterday(day) { return "Yesterday" }
    return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
  }

  /// Takes the meetings the app last read in the background; never reads the folder itself.
  func reload() {
    if library.root != app.meetingsRoot {
      library = MeetingLibrary(root: app.meetingsRoot)
      records = []
      editor = nil
    }
    let next = app.meetings.map { incoming in
      // A background scan can finish after an edit with the version it read before the edit.
      if let edited = records.first(where: { $0.id == incoming.id }),
        edited.revision > incoming.revision
      {
        return edited
      }
      return incoming
    }
    if next != records { records = next }
    let recording = records.first { $0.status == .recording }?.id
    if let recording, recording != followedRecording { selection = recording }
    followedRecording = recording
    if let selection, !records.contains(where: { $0.id == selection }) {
      self.selection = records.first?.id
    }
    if let record = selectedRecord, playback.url != playableAudio(of: record) {
      playback.load(playableAudio(of: record))
    }
  }

  func turns(of record: MeetingRecord) -> [TranscriptTurn] {
    record.segments.enumerated().map { index, segment in
      TranscriptTurn(
        id: index, start: segment.start, timestamp: MeetingLibrary.timestamp(segment.start),
        speaker: segment.speaker, text: segment.text)
    }
  }

  func editText(_ segment: Int, in record: MeetingRecord) {
    guard record.status == .complete, record.segments.indices.contains(segment) else { return }
    editor = .transcript(record, segment: segment)
  }

  func saveTitle(_ title: String, for record: MeetingRecord) async throws -> MeetingRecord {
    try await changeRecord { library in
      try library.updateMeeting(record.id, title: .some(title), expectedRevision: record.revision)
        .record
    }
  }

  func editSpeakers(_ record: MeetingRecord) { editor = .speakers(record) }

  func saveText(_ text: String, segment: Int, in record: MeetingRecord) async throws
    -> MeetingRecord
  {
    let change = MeetingTextChange(segmentID: record.segmentID(at: segment), text: text)
    return try await changeRecord { library in
      try library.editTranscript(
        record.id, changes: [change], expectedRevision: record.revision
      ).record
    }
  }

  func saveSpeakerNames(_ names: [String: String], for record: MeetingRecord) async throws
    -> MeetingRecord
  {
    var changes: [String: String?] = [:]
    for speaker in record.speakers {
      let name = try MeetingLibrary.validatedSpeakerName(names[speaker.label])
      if name != speaker.name { changes[speaker.label] = .some(name) }
    }
    guard !changes.isEmpty else { return record }
    let savedNames = changes
    return try await changeRecord { library in
      try library.updateMeeting(
        record.id, names: savedNames, expectedRevision: record.revision
      ).record
    }
  }

  func mergeSpeakers(
    in record: MeetingRecord, keep: String, merge: String, name: String?
  ) async throws -> MeetingRecord {
    try await changeRecord { library in
      try library.mergeSpeakers(
        record.id, keep: keep, merge: [merge], name: name, expectedRevision: record.revision
      ).record
    }
  }

  func latestRecord(_ id: String) async throws -> MeetingRecord {
    try await changeRecord { try $0.load(id) }
  }

  private func changeRecord(
    _ operation: @escaping @Sendable (MeetingLibrary) throws -> MeetingRecord
  ) async throws -> MeetingRecord {
    let root = library.root
    let record = try await Task.detached(priority: .userInitiated) {
      try operation(MeetingLibrary(root: root))
    }.value
    if library.root == root {
      if let index = records.firstIndex(where: { $0.id == record.id }) {
        records[index] = record
      }
      app.send(.refreshLibrary)
    }
    return record
  }

  func copyTranscript(_ record: MeetingRecord) {
    app.send(.copyText(MeetingLibrary.transcriptText(record)))
  }

  func canRetry(_ record: MeetingRecord) -> Bool {
    record.status.needsAttention && app.retryable.contains(record.id)
  }

  func retry(_ record: MeetingRecord) { app.send(.meeting(.retry(id: record.id))) }

  func discard(_ record: MeetingRecord) {
    playback.load(nil)
    app.send(.meeting(.discard(id: record.id)))
  }

  func delete(_ record: MeetingRecord) {
    playback.load(nil)
    app.send(.meeting(.delete(id: record.id)))
  }

  func playableAudio(of record: MeetingRecord) -> URL? {
    switch record.status {
    case .recording, .saving: return nil
    default: return app.audioFiles[record.id]
    }
  }

  /// Opens a linked passage without starting audio playback.
  func open(_ link: MeetingLink) {
    guard let record = records.first(where: { $0.id == link.meetingID }) else {
      showNotice(
        "There is no meeting \"\(link.meetingID)\" on this Mac. It may have been deleted.")
      return
    }
    selection = record.id
    playback.pause()
    focus = nil
    let index: Int
    if let passage = link.passageID {
      guard let resolved = try? record.segmentIndex(for: passage) else {
        showNotice("This passage is not in the transcript.")
        return
      }
      index = resolved
    } else if let time = link.time {
      guard let resolved = MeetingLink.segmentIndex(at: time, in: record.segments) else {
        showNotice("This meeting has no transcript to jump to.")
        return
      }
      guard !MeetingLink.isPastEnd(time, of: record) else {
        showNotice("This time is past the end of the meeting.")
        return
      }
      index = resolved
    } else {
      return
    }
    focus = TranscriptFocus(meetingID: record.id, segment: index)
    playback.seek(to: record.segments[index].start)
    if let error = playback.error { showNotice(error) }
  }

  func showNotice(_ text: String) {
    notice = text
    AppLog.event("library.notice", text)
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      guard !Task.isCancelled else { return }
      self?.notice = nil
    }
  }

  func dismissNotice() {
    noticeTask?.cancel()
    notice = nil
  }

  private func selectionChanged() {
    if focus?.meetingID != selection { focus = nil }
    playback.load(selectedRecord.flatMap(playableAudio(of:)))
  }
}

/// Owns the library window. The app shows a Dock icon only while this window is open.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
  let model: LibraryModel
  private var window: NSWindow?
  private var refreshTimer: Timer?

  init(model: LibraryModel) {
    self.model = model
    super.init()
  }

  var isVisible: Bool { window?.isVisible ?? false }

  func show(selecting id: String? = nil) {
    let window = self.window ?? makeWindow()
    self.window = window
    model.reload()
    model.app.send(.refreshLibrary)
    if let id, model.records.contains(where: { $0.id == id }) {
      model.selection = id
    } else if model.selection == nil {
      model.selection = model.records.first?.id
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.mainMenu = makeMainMenu()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    startRefreshing()
    AppLog.event("library.opened", id ?? "")
  }

  /// Shows the Library at the meeting and moment a `meetingnotes://meeting/…` link names.
  func show(_ link: MeetingLink) {
    show()
    model.open(link)
    AppLog.event("library.link", link.string)
  }

  func windowWillClose(_ notification: Notification) {
    refreshTimer?.invalidate()
    refreshTimer = nil
    model.playback.pause()
    NSApp.setActivationPolicy(.accessory)
    AppLog.event("library.closed")
  }

  private func startRefreshing() {
    guard refreshTimer == nil else { return }
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.model.app.send(.refreshLibrary) }
    }
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingController(rootView: LibraryView(model: model))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: hosting)
    window.title = "Meeting Notes"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 1040, height: 700))
    window.contentMinSize = NSSize(width: 720, height: 460)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("MeetingNotesLibrary")
    return window
  }

  private func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      holder.submenu = menu
      main.addItem(holder)
    }
    func item(
      _ title: String, _ action: Selector, _ key: String = "",
      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      return item
    }
    submenu(
      "Meeting Notes",
      [
        item(
          "About Meeting Notes", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Hide Meeting Notes", #selector(NSApplication.hide(_:)), "h"),
        item("Quit Meeting Notes", #selector(NSApplication.terminate(_:)), "q"),
      ])
    submenu(
      "File",
      [
        item("Start Recording", #selector(startRecording), "r", [.command, .shift], target: self),
        item("Stop & Transcribe", #selector(stopRecording), ".", target: self),
        .separator(),
        item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
      ])
    submenu(
      "Edit",
      [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        item("Find…", #selector(focusSearch), "f", target: self),
      ])
    submenu(
      "Meeting",
      [
        item("Play/Pause Audio", #selector(togglePlayback), "p", target: self),
        item("Back 15 Seconds", #selector(skipBack), "[", target: self),
        item("Forward 15 Seconds", #selector(skipForward), "]", target: self),
        .separator(),
        item("Copy Transcript", #selector(copyTranscript), "c", [.command, .shift], target: self),
        item("Edit Speakers…", #selector(renameSpeakers), "r", target: self),
        .separator(),
        item("Retry Transcription", #selector(retry), "t", [.command, .shift], target: self),
        item("Move to Trash…", #selector(moveToTrash), "\u{8}", target: self),
        .separator(),
        item("Show Panel", #selector(showPanel), "", target: self),
        item("Settings…", #selector(showSettings), ",", target: self),
      ])
    submenu(
      "Window",
      [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
      ])
    return main
  }

  private var selected: MeetingRecord? { model.selectedRecord }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(startRecording): return model.app.canStart
    case #selector(stopRecording): return model.app.isRecording
    case #selector(togglePlayback), #selector(skipBack), #selector(skipForward):
      return model.playback.url != nil && model.playback.error == nil
    case #selector(copyTranscript), #selector(renameSpeakers):
      return selected?.status == .complete
    case #selector(retry): return selected.map(model.canRetry) ?? false
    case #selector(moveToTrash):
      guard let selected else { return false }
      return selected.status == .complete || selected.status.needsAttention
        || selected.status == .queued
    default: return true
    }
  }

  @objc private func startRecording() {
    model.app.send(.meeting(.start(title: nil)))
  }
  @objc private func stopRecording() { model.app.send(.meeting(.stop)) }
  @objc private func focusSearch() { model.searchFocused = true }
  @objc private func showPanel() { model.app.send(.showPanel) }
  @objc private func showSettings() { model.app.send(.openSettings(.general)) }
  @objc private func togglePlayback() { model.playback.togglePlayback() }
  @objc private func skipBack() { model.playback.skip(by: -15) }
  @objc private func skipForward() { model.playback.skip(by: 15) }
  @objc private func copyTranscript() { selected.map(model.copyTranscript) }
  @objc private func renameSpeakers() { selected.map(model.editSpeakers) }
  @objc private func retry() { selected.map(model.retry) }
  @objc private func moveToTrash() {
    guard let selected else { return }
    if selected.status == .complete {
      model.pendingDeletion = selected
    } else {
      model.discard(selected)
    }
  }
}

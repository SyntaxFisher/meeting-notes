import SwiftUI

extension StatusTone {
  var color: Color {
    switch self {
    case .neutral: return .secondary
    case .recording: return .red
    case .muted: return .orange
    case .working: return .blue
    case .success: return .green
    case .warning: return .orange
    case .error: return .red
    }
  }
}

/// Recording stays available while recent meetings finish in the background.
struct PanelView: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RecordControl(model: model)
        .padding(6)
      if !model.attention.isEmpty {
        Divider()
        AttentionSection(model: model)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
      }
      if !recent.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 2) {
          Text("Last Meetings")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
          ForEach(recent, id: \.id) { meeting in
            RecentMeetingRow(model: model, meeting: meeting)
          }
        }
        .padding(6)
      }
      Divider()
      VStack(spacing: 0) {
        if model.suggestsConnectingAgent {
          PanelRow(title: "Connect an Agent…", symbol: "sparkles") {
            model.send(.openSettings(.agents))
          }
          .help("Lets Codex, Claude Code or pi read your meetings")
        }
        PanelRow(title: "Open App", symbol: "books.vertical") {
          model.send(.showLibrary(id: nil))
        }
        .keyboardShortcut("l", modifiers: .command)
        .help("Opens the Library with all meetings (⌘L)")
        PanelRow(title: "Settings", symbol: "gearshape") {
          model.send(.openSettings(.general))
        }
        .keyboardShortcut(",", modifiers: .command)
        .help("Settings (⌘,)")
      }
      .padding(6)
    }
    .frame(width: 320)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var recent: [MeetingRecord] {
    PanelMeetings.recent(records: model.meetings, pending: model.queue.map(\.record))
  }
}

/// The header: says what is happening and is the button that starts or stops a recording, or
/// leads to the fix when recording is impossible. Hovering reveals what a click does and, for
/// work that can be thrown away, a trash button.
private struct RecordControl: View {
  let model: AppModel
  @State private var hoveringRow = false
  @State private var hoveringMain = false
  @FocusState private var accessoryFocused: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let status = model.headerStatus
      let action = status.headerAction(canStart: model.canStart)
      HStack(spacing: 0) {
        main(status: status, action: action, now: context.date)
        if let accessory = status.headerAccessory {
          AccessoryButton(accessory: accessory) { perform(accessory) }
            .opacity(hoveringRow || accessoryFocused ? 1 : 0)
            .focused($accessoryFocused)
            .padding(.trailing, 8)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(background(status: status, clickable: action != nil))
      )
      .onHover { hoveringRow = $0 }
      .animation(.easeOut(duration: 0.12), value: hoveringRow)
      .animation(.easeOut(duration: 0.12), value: hoveringMain)
    }
  }

  @ViewBuilder
  private func main(status: PanelStatus, action: HeaderAction?, now: Date) -> some View {
    let content = HeaderContent(
      status: status, action: action, hovering: hoveringMain, now: now
    )
    .padding(.vertical, 10)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    if let action {
      Button {
        perform(action)
      } label: {
        content
      }
      .buttonStyle(PressDimmingStyle())
      .keyboardShortcut(.defaultAction)
      .onHover { hoveringMain = $0 }
      .help(help(for: action))
      .accessibilityLabel(action.title)
      .accessibilityValue(status.spokenSummary(now: now))
      .accessibilityIdentifier("record-control")
      .accessibilityActions {
        if let accessory = status.headerAccessory {
          Button(accessory.title) { perform(accessory) }
        }
      }
    } else {
      content
        .help(model.startBlockedReason ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spokenSummary(now: now))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("record-control")
    }
  }

  private func background(status: PanelStatus, clickable: Bool) -> Color {
    switch status.tone {
    case .recording: return .red.opacity(hoveringRow ? 0.16 : 0.1)
    case .muted: return .orange.opacity(hoveringRow ? 0.16 : 0.1)
    default: return clickable && hoveringRow ? .primary.opacity(0.07) : .clear
    }
  }

  private func help(for action: HeaderAction) -> String {
    switch action {
    case .start:
      return model.queue.isEmpty
        ? "Start recording now" : "Start a new recording; earlier meetings keep processing"
    case .stop: return "Stop recording and transcribe it"
    case .setUpPermissions: return "Allow what Meeting Notes needs to record"
    case .openFolderSettings: return "Allow access in Privacy & Security > Files and Folders"
    }
  }

  private func perform(_ action: HeaderAction) {
    switch action {
    case .start: model.send(.meeting(.start(title: nil)))
    case .stop: model.send(.meeting(.stop))
    case .setUpPermissions: model.send(.showOnboarding)
    case .openFolderSettings: PermissionAccess.openFilesAndFoldersSettings()
    }
  }

  private func perform(_ accessory: HeaderAccessory) {
    switch accessory {
    case .discardRecording: model.send(.meeting(.stopAndDiscard))
    case .discardMeeting(let id): model.send(.meeting(.discard(id: id)))
    case .dismissProblem: model.send(.dismissProblem)
    }
  }
}

private struct HeaderContent: View {
  let status: PanelStatus
  let action: HeaderAction?
  let hovering: Bool
  let now: Date

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      HeaderIcon(status: status, action: hovering ? action : nil)
      VStack(alignment: .leading, spacing: 2) {
        Text(status.headline(now: now))
          .font(.headline)
          .monospacedDigit()
          .foregroundStyle(
            status.tone == .recording ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        if let title = status.meetingTitle {
          Text(title)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if let detail = status.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        if status == .starting {
          ThinProgress(fraction: nil, label: "Starting recording").padding(.top, 4)
        }
      }
      Spacer(minLength: 0)
      if action == .setUpPermissions || action == .openFolderSettings {
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

/// Hover reveals the next recording action: green to start, red to stop.
private struct HeaderIcon: View {
  let status: PanelStatus
  let action: HeaderAction?

  var body: some View {
    ZStack {
      Circle().fill(color.opacity(0.16))
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(color)
    }
    .frame(width: 36, height: 36)
    .accessibilityHidden(true)
  }

  private var showsAction: Bool { action == .start || action == .stop }

  private var symbol: String {
    switch action {
    case .start: return "play.fill"
    case .stop: return "stop.fill"
    default: return status.symbol
    }
  }

  private var size: CGFloat { showsAction ? 13 : 16 }
  private var color: Color {
    switch action {
    case .start: return .green
    case .stop: return .red
    default: return status.tone.color
    }
  }
}

private struct AccessoryButton: View {
  let accessory: HeaderAccessory
  var usesKeyboardShortcut = true
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: accessory.symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(hovering ? tint : Color.secondary)
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? tint.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(PressDimmingStyle())
    .keyboardShortcut(
      isDestructive && usesKeyboardShortcut ? KeyboardShortcut(.delete, modifiers: .command) : nil
    )
    .onHover { hovering = $0 }
    .help(
      usesKeyboardShortcut
        ? accessory.help : accessory.help.replacingOccurrences(of: " (⌘⌫)", with: "")
    )
    .accessibilityLabel(accessory.title)
  }

  private var isDestructive: Bool { accessory != .dismissProblem }
  private var tint: Color { isDestructive ? .red : .primary }
}

private struct PressDimmingStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
  }
}

/// A full-width row with an icon and a label that highlights under the pointer, like a menu
/// item.
private struct PanelRow: View {
  let title: String
  let symbol: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
          .frame(width: 16)
          .accessibilityHidden(true)
        Text(title)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowStyle())
  }

  private struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      Highlight(configuration: configuration)
    }

    struct Highlight: View {
      let configuration: Configuration
      @State private var hovering = false

      var body: some View {
        configuration.label
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0))
          )
          .onHover { hovering = $0 }
      }
    }
  }
}

private struct ThinProgress: View {
  let fraction: Double?
  let label: String

  var body: some View {
    Group {
      if let fraction {
        ProgressView(value: min(1, max(0, fraction)))
      } else {
        ProgressView().progressViewStyle(.linear)
      }
    }
    .controlSize(.small)
    .accessibilityLabel(label)
  }
}

/// Every failed, interrupted or untranscribed meeting, each with its own Retry and Discard.
private struct AttentionSection: View {
  let model: AppModel
  static let visible = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.attention.prefix(Self.visible)) { item in
        AttentionRow(model: model, item: item)
      }
      if model.attention.count > Self.visible {
        Button("\(model.attention.count - Self.visible) more in the Library…") {
          model.send(.showLibrary(id: model.attention[Self.visible].id))
        }
        .buttonStyle(.link)
        .font(.caption)
      }
    }
  }
}

private struct AttentionRow: View {
  let model: AppModel
  let item: MeetingItem

  var body: some View {
    HStack(spacing: 8) {
      Button {
        model.send(.showLibrary(id: item.id))
      } label: {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.record.displayTitle)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(item.record.attentionReason)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(item.record.error ?? item.record.attentionReason)
      Spacer(minLength: 4)
      Button("Discard") { model.send(.meeting(.discard(id: item.id))) }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      if item.canRetry {
        Button("Retry") { model.send(.meeting(.retry(id: item.id))) }
      }
    }
    .controlSize(.small)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(item.record.displayTitle), needs attention: \(item.record.error ?? item.record.attentionReason)"
    )
  }
}

/// The age of a date as text, such as "yesterday". The panel's view lives for days while hidden,
/// so the text is formatted against the system clock each minute and each time a window becomes
/// key, never left to a self-updating date text.
private struct RelativeAge: View {
  let date: Date
  @State private var shownAt = Date.now

  var body: some View {
    TimelineView(.everyMinute) { _ in
      Text(date.formatted(.relative(presentation: .named)))
        .id(shownAt)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      shownAt = .now
    }
  }
}

private struct RecentMeetingRow: View {
  let model: AppModel
  let meeting: MeetingRecord
  @State private var hovering = false
  @FocusState private var accessoryFocused: Bool

  var body: some View {
    HStack(spacing: 0) {
      Button {
        model.send(.showLibrary(id: meeting.id))
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: processing ? "text.bubble" : "doc.text")
            .foregroundStyle(processing ? Color.orange : .secondary)
            .frame(width: 16)
            .padding(.top, 2)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(meeting.displayTitle)
              .lineLimit(1)
              .truncationMode(.middle)
            if processing {
              Text(progressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              ThinProgress(fraction: progressFraction, label: progressLabel)
                .accessibilityHidden(true)
            } else {
              RelativeAge(date: meeting.startedAt)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
          if !processing {
            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.top, 3)
              .accessibilityHidden(true)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(PressDimmingStyle())
      .help("Open in the Library")
      .accessibilityLabel(meeting.displayTitle)
      .accessibilityValue(
        processing ? progressLabel : meeting.startedAt.formatted(.relative(presentation: .named))
      )
      .accessibilityIdentifier("open-meeting-\(meeting.id)")
      if processing {
        AccessoryButton(accessory: .discardMeeting(id: meeting.id), usesKeyboardShortcut: false) {
          model.send(.meeting(.discard(id: meeting.id)))
        }
        .opacity(hovering || accessoryFocused ? 1 : 0)
        .focused($accessoryFocused)
        .padding(.trailing, 4)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(.primary.opacity(hovering ? 0.07 : 0))
    )
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
  }

  private var processing: Bool { meeting.status.isInProgress }

  private var progress: TranscriptionProgress {
    TranscriptionProgress(recordStage: meeting.stage ?? "")
  }

  private var progressFraction: Double? {
    meeting.status == .transcribing ? meeting.progress ?? progress.fraction : nil
  }

  private var progressLabel: String {
    switch meeting.status {
    case .saving: return "Processing audio"
    case .queued: return "Waiting to transcribe"
    case .transcribing:
      if progress.stage == .saving { return "Finishing" }
      if let fraction = progressFraction {
        return "Transcribing · \(Int(min(1, max(0, fraction)) * 100))%"
      }
      return progress.stage == .starting ? "Starting transcription" : progress.description
    default: return "Processing"
    }
  }
}

extension MeetingRecord {
  /// Why a meeting needs attention, in a few words; `error` has the full reason.
  var attentionReason: String {
    switch status {
    case .interrupted: return "Interrupted"
    case .untranscribed: return "Not transcribed"
    default:
      guard let error, let sentence = error.split(separator: ".").first else {
        return "Transcription failed"
      }
      return String(sentence).trimmingCharacters(in: .whitespaces)
    }
  }
}

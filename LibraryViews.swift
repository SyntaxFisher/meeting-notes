import SwiftUI

struct LibraryView: View {
  @Bindable var model: LibraryModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    NavigationSplitView {
      MeetingSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
    } detail: {
      if let record = model.selectedRecord {
        MeetingDetail(model: model, record: record)
          .id(record.id)
      } else {
        ContentUnavailableView(
          "No Meeting Selected", systemImage: "waveform",
          description: Text("Choose a meeting in the sidebar."))
      }
    }
    .overlay(alignment: .top) {
      if let notice = model.notice {
        NoticeBanner(text: notice) { model.dismissNotice() }
          .padding(.top, 12)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.default, value: model.notice)
    .navigationTitle("Meeting Notes")
    .searchable(
      text: $model.searchText, placement: .sidebar, prompt: "Search"
    )
    .searchFocused($searchFocused)
    .onChange(of: model.searchFocused) { _, focused in
      if focused {
        searchFocused = true
        model.searchFocused = false
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.app.send(.openSettings(.general))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Settings (⌘,)")
        .accessibilityIdentifier("library-settings")
      }
    }
    .sheet(item: $model.editor) { editor in
      switch editor {
      case .transcript(let record, let segment):
        TranscriptEditorSheet(model: model, record: record, segment: segment)
      case .speakers(let record):
        EditSpeakersSheet(model: model, record: record)
      }
    }
    .confirmationDialog(
      "Move “\(model.pendingDeletion?.displayTitle ?? "")” to the Trash?",
      isPresented: Binding(
        get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
      titleVisibility: .visible, presenting: model.pendingDeletion
    ) { record in
      Button("Move to Trash", role: .destructive) { model.delete(record) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "Its audio, transcript, record and any other files starting with its id are moved to the Trash."
      )
    }
    .alert(
      "Meeting Notes",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") {}
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

struct MeetingSidebar: View {
  @Bindable var model: LibraryModel

  var body: some View {
    let groups = model.groups
    List(selection: $model.selection) {
      ForEach(groups) { group in
        Section(group.title) {
          ForEach(group.records, id: \.id) { record in
            MeetingRow(record: record)
              .tag(record.id)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if case .loading(let updating) = model.app.folderAccess {
        ContentUnavailableView {
          Label(updating ? "Updating Meetings" : "Loading Meetings", systemImage: "hourglass")
        } description: {
          if updating {
            Text("Converting meetings from an earlier version. This can take a few minutes.")
          }
        } actions: {
          ProgressView().controlSize(.small)
        }
      } else if model.app.folderAccess != .granted {
        ContentUnavailableView(
          "Waiting for Access", systemImage: "folder",
          description: Text(
            "Allow access to \(PanelStatus.folderName(of: model.app.meetingsRoot))."))
      } else if groups.isEmpty {
        if model.searchText.isEmpty {
          ContentUnavailableView(
            "No Meetings Yet", systemImage: "waveform",
            description: Text("Recordings appear here."))
        } else {
          ContentUnavailableView.search(text: model.searchText)
        }
      }
    }
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let record = model.records.first(where: { $0.id == id }) {
        MeetingActions(model: model, record: record)
      }
    }
  }
}

struct MeetingRow: View {
  let record: MeetingRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(record.displayTitle)
        .lineLimit(1)
      HStack(spacing: 4) {
        Text(record.startedAt, format: .dateTime.hour().minute())
          .foregroundStyle(.secondary)
        if record.status != .complete {
          Text("·").foregroundStyle(.secondary)
          StatusBadge(record: record)
        }
      }
      .font(.subheadline)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    var parts = [
      record.displayTitle,
      record.startedAt.formatted(date: .abbreviated, time: .shortened),
    ]
    if let duration = record.durationSeconds, record.status != .recording {
      parts.append(Format.spokenDuration(duration))
    }
    parts.append(StatusBadge.label(record))
    return parts.joined(separator: ", ")
  }
}

struct StatusBadge: View {
  let record: MeetingRecord
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    HStack(spacing: 5) {
      Text(Self.label(record))
      if record.status == .transcribing, let fraction = record.progress {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .frame(width: 44)
          .accessibilityHidden(true)
      }
    }
    .foregroundStyle(
      prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Self.color(record.status)))
  }

  static func label(_ record: MeetingRecord) -> String {
    switch record.status {
    case .recording: return "Recording"
    case .saving: return "Saving"
    case .queued: return "Queued"
    case .transcribing: return "Transcribing"
    case .complete: return "Transcript ready"
    case .failed: return "Failed"
    case .interrupted: return "Interrupted"
    case .untranscribed: return "Not transcribed"
    }
  }

  static func color(_ status: MeetingStatus) -> Color {
    switch status {
    case .recording: return .red
    case .saving, .queued, .transcribing: return .blue
    case .failed, .interrupted: return .orange
    case .complete: return .green
    case .untranscribed: return .secondary
    }
  }
}

struct MeetingActions: View {
  let model: LibraryModel
  let record: MeetingRecord

  var body: some View {
    if record.status == .complete {
      Button("Copy Transcript") { model.copyTranscript(record) }
      Button("Edit Speakers…") { model.editSpeakers(record) }
    }
    if record.status.needsAttention {
      Button("Retry Transcription") { model.retry(record) }
        .disabled(!model.canRetry(record))
    }
    Divider()
    if record.status == .complete {
      Button("Move to Trash…", role: .destructive) { model.pendingDeletion = record }
    } else {
      Button("Discard", role: .destructive) { model.discard(record) }
        .disabled(!(record.status.needsAttention || record.status == .queued))
    }
  }
}

struct MeetingDetail: View {
  let model: LibraryModel
  let record: MeetingRecord
  @State private var followsPlayback = true
  @State private var visibleRows: Set<Int> = []
  @State private var compactHeader = false
  @State private var currentSegment: Int?
  @State private var jumpTarget: Int?
  @State private var scrollPosition = ScrollPosition(idType: String.self)
  @State private var scrollingToTarget = false
  @State private var scrollIntent = TranscriptScrollIntent()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var pendingJumpTarget: Int? {
    guard let currentSegment, !scrollingToTarget, !visibleRows.contains(currentSegment)
    else { return nil }
    return currentSegment
  }

  var body: some View {
    let turns = model.turns(of: record)
    let focus = model.focus?.meetingID == record.id ? model.focus : nil
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        MeetingHeader(model: model, record: record, compact: compactHeader)
        if model.playableAudio(of: record) != nil {
          PlayerBar(playback: model.playback)
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, compactHeader ? 10 : 20)
      .frame(maxWidth: 860, alignment: .leading)
      .frame(maxWidth: .infinity)
      .background(.bar)
      Divider()
      ScrollView {
        TranscriptView(
          record: record, turns: turns, playback: model.playback,
          currentSegment: currentSegment,
          canPlay: model.playableAudio(of: record) != nil, focusedSegment: focus?.segment,
          edit: { model.editText($0, in: record) }
        ) {
          switch record.status {
          case .recording: LiveCard(model: model, record: record)
          case .saving, .queued, .transcribing: ProgressCard(model: model, record: record)
          case .failed, .interrupted, .untranscribed:
            AttentionCard(model: model, record: record)
          case .complete: EmptyView()
          }
        }
        .padding(24)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollPosition($scrollPosition, anchor: .top)
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
        visibleRows = Set(
          ids.compactMap { Int($0.replacingOccurrences(of: "segment-", with: "")) })
      }
      .background {
        TranscriptScrollWheel { delta, began in
          followsPlayback = false
          scrollingToTarget = false
          if let compact = scrollIntent.scrollWheel(
            delta: delta, began: began, compact: compactHeader)
          {
            setHeader(compact)
          }
        }
      }
      .onScrollPhaseChange { _, phase in
        if phase == .interacting {
          followsPlayback = false
          scrollIntent.cancelTarget()
        }
      }
      .onScrollGeometryChange(for: ScrollMeasurements.self) { geometry in
        ScrollMeasurements(
          offset: geometry.contentOffset.y, height: geometry.containerSize.height,
          contentHeight: geometry.contentSize.height)
      } action: { _, measurement in
        scrollIntent.observe(
          offset: measurement.offset, height: measurement.height,
          contentHeight: measurement.contentHeight)
      }
      .onChange(of: currentSegment) { _, segment in
        if followsPlayback { scroll(to: segment) }
      }
      .onChange(of: model.playback.isPlaying) { _, playing in
        if followsPlayback && playing { scroll(to: currentSegment) }
      }
      .task(id: focus?.id) {
        guard let segment = focus?.segment else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let target = turns.last { $0.id <= segment }?.id
        scroll(to: target, force: true, animated: false)
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        scroll(to: target, force: true)
      }
      .task(id: pendingJumpTarget) {
        let target = pendingJumpTarget
        if target != nil { try? await Task.sleep(for: .milliseconds(180)) }
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { jumpTarget = target }
      }
      .overlay(alignment: .bottom) {
        if let segment = jumpTarget {
          Button {
            followsPlayback = true
            jumpTarget = nil
            scroll(to: currentSegment ?? segment, force: true)
          } label: {
            Label("Jump to Now", systemImage: jumpSymbol(segment))
              .padding(.horizontal, 12).padding(.vertical, 8)
          }
          .buttonStyle(.plain)
          .background(.regularMaterial, in: Capsule())
          .shadow(radius: 4, y: 2)
          .padding(.bottom, 16)
          .accessibilityIdentifier("jump-to-playing")
          .transition(.opacity)
        }
      }
    }
    .background {
      PlaybackSegmentObserver(turns: turns, playback: model.playback) { currentSegment = $0 }
    }
  }

  private func setHeader(_ compact: Bool) {
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
      compactHeader = compact
    } completion: {
      scrollIntent.headerSettled()
    }
  }

  private func scroll(to segment: Int?, force: Bool = false, animated: Bool = true) {
    guard let segment, scrollIntent.shouldScroll(to: segment, force: force) else { return }
    scrollingToTarget = true
    withAnimation(reduceMotion || !animated ? nil : .smooth(duration: 0.7)) {
      scrollPosition.scrollTo(id: TranscriptTurn.rowID(segment), anchor: .top)
    } completion: {
      scrollingToTarget = false
    }
  }

  private func jumpSymbol(_ segment: Int) -> String {
    let first = visibleRows.min()
    return (first.map { segment < $0 } ?? true) ? "chevron.up" : "chevron.down"
  }
}

private struct ScrollMeasurements: Equatable {
  let offset: Double
  let height: Double
  let contentHeight: Double
}

private struct PlaybackSegmentObserver: View {
  let turns: [TranscriptTurn]
  let playback: AudioPlayback
  let changed: (Int?) -> Void

  private var activeSegment: Int? {
    guard playback.currentTime > 0 else { return nil }
    return turns.last { $0.start <= playback.currentTime }?.id
  }

  var body: some View {
    Color.clear
      .onChange(of: activeSegment, initial: true) { _, id in
        changed(id)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

struct MeetingHeader: View {
  let model: LibraryModel
  let record: MeetingRecord
  var compact = false
  @State private var speakersHovered = false
  @State private var copied = false
  @State private var copyGeneration = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      EditableMeetingTitle(model: model, record: record, compact: compact)
      if !compact {
        if let summary = record.summary, !summary.isEmpty {
          Text(summary)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .textSelection(.enabled)
        }
        HStack(spacing: 10) {
          HStack(spacing: 12) {
            Text(
              "\(record.startedAt.formatted(date: .long, time: .omitted)), \(record.startedAt.formatted(date: .omitted, time: .shortened))"
            )
            .monospacedDigit()
            if let duration = record.durationSeconds, record.status != .recording {
              Text(Format.compactDuration(duration))
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.45), in: Capsule())
                .accessibilityLabel(Format.spokenDuration(duration))
            }
          }
          .foregroundStyle(.secondary)
          Spacer()
          if record.status == .complete {
            Button {
              model.copyTranscript(record)
              copyGeneration += 1
              withAnimation(.snappy(duration: 0.2)) { copied = true }
            } label: {
              ZStack {
                Image(systemName: "doc.on.doc").hidden()
                Image(systemName: "checkmark").hidden()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                  .contentTransition(.symbolEffect(.replace, options: .speed(2)))
              }
            }
            .help(copied ? "Copied" : "Copy the transcript")
            .accessibilityLabel(copied ? "Transcript Copied" : "Copy Transcript")
            .task(id: copyGeneration) {
              guard copied else { return }
              do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
              withAnimation(.snappy(duration: 0.2)) { copied = false }
            }
          }
          Button(role: .destructive) {
            if record.status == .complete {
              model.pendingDeletion = record
            } else {
              model.discard(record)
            }
          } label: {
            Image(systemName: "trash")
          }
          .help("Move to Trash…")
          .accessibilityLabel("Move to Trash")
          .disabled(
            !(record.status == .complete || record.status.needsAttention
              || record.status == .queued))
        }
        if !record.speakers.isEmpty {
          SpeakerFlowLayout(spacing: 8) {
            ForEach(Array(record.speakers.enumerated()), id: \.element.label) { index, speaker in
              SpeakerChip(
                name: speaker.displayName, color: SpeakerPalette.color(index),
                isLocalUser: speaker.isLocalUser
              )
              .fixedSize()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
          .background(
            .primary.opacity(speakersHovered && record.status == .complete ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: 10)
          )
          .contentShape(Rectangle())
          .onHover { speakersHovered = $0 }
          .onTapGesture { if record.status == .complete { model.editSpeakers(record) } }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Edit Speakers")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { if record.status == .complete { model.editSpeakers(record) } }
        }
      }
    }
  }
}

struct SpeakerChip: View {
  let name: String
  let color: Color
  var isLocalUser = false

  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(name)
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(color.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isLocalUser ? "\(name), this Mac's microphone" : name)
  }
}

struct LiveCard: View {
  let model: LibraryModel
  let record: MeetingRecord

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: model.app.mutedInTeams ? "mic.slash.fill" : "record.circle.fill")
            .foregroundStyle(model.app.mutedInTeams ? .orange : .red)
            .symbolEffect(.pulse, isActive: !model.app.mutedInTeams)
            .accessibilityHidden(true)
          Text(model.app.mutedInTeams ? "Muted in Teams" : "Recording")
            .font(.title3.weight(.semibold))
          Spacer()
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(record.startedAt)
            Text(Format.clock(elapsed))
              .font(.system(.title2, design: .rounded).monospacedDigit())
              .accessibilityLabel("Elapsed time \(Format.spokenDuration(elapsed))")
          }
        }
        HStack {
          Button {
            model.app.send(.meeting(.stop))
          } label: {
            Label("Stop & Transcribe", systemImage: "stop.fill")
          }
          .buttonStyle(.borderedProminent)
          Button("Discard") { model.app.send(.meeting(.stopAndDiscard)) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop and move this recording to the Trash")
        }
      }
      .padding(8)
    }
  }
}

struct ProgressCard: View {
  let model: LibraryModel
  let record: MeetingRecord

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text(title)
          .font(.title3.weight(.semibold))
        Group {
          if record.status == .transcribing, let fraction = record.progress {
            ProgressView(value: fraction)
          } else {
            ProgressView().progressViewStyle(.linear)
          }
        }
        .controlSize(.small)
        .accessibilityLabel(record.stage ?? title)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var title: String {
    switch record.status {
    case .saving: return "Saving…"
    case .queued: return "Waiting to transcribe…"
    default: return "Transcribing…"
    }
  }
}

struct AttentionCard: View {
  let model: LibraryModel
  let record: MeetingRecord

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Label(record.attentionReason, systemImage: "exclamationmark.triangle.fill")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.orange)
        if let error = record.error, error != record.attentionReason {
          Text(error)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        HStack {
          if model.canRetry(record) {
            Button {
              model.retry(record)
            } label: {
              Label(
                record.status == .untranscribed ? "Transcribe" : "Retry",
                systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
          } else {
            Text("No audio was saved.").foregroundStyle(.secondary)
          }
          Button("Discard") { model.discard(record) }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct PlayerBar: View {
  let playback: AudioPlayback

  var body: some View {
    HStack(spacing: 12) {
      Button {
        playback.togglePlayback()
      } label: {
        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 18)
      }
      .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
      .help("Play or pause (⌘P)")
      Button {
        playback.skip(by: -15)
      } label: {
        Image(systemName: "gobackward.15")
      }
      .accessibilityLabel("Back 15 seconds")
      Button {
        playback.skip(by: 15)
      } label: {
        Image(systemName: "goforward.15")
      }
      .accessibilityLabel("Forward 15 seconds")
      Slider(
        value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
        in: 0...max(playback.duration, 1)
      )
      .accessibilityLabel("Playback position")
      .accessibilityValue(
        "\(Format.spokenDuration(playback.currentTime)) of \(Format.spokenDuration(playback.duration))"
      )
      Text("\(Format.clock(playback.currentTime)) / \(Format.clock(playback.duration))")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .buttonStyle(.borderless)
    .disabled(playback.error != nil)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    .overlay(alignment: .bottomLeading) {
      if let error = playback.error {
        Text(error).font(.caption).foregroundStyle(.red).offset(y: 18)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Audio player")
  }
}

struct TranscriptView<Header: View>: View {
  let record: MeetingRecord
  let turns: [TranscriptTurn]
  let playback: AudioPlayback
  let currentSegment: Int?
  let canPlay: Bool
  var focusedSegment: Int?
  var edit: ((Int) -> Void)?
  @ViewBuilder let header: () -> Header

  var body: some View {
    let labels = record.speakers.map(\.label)
    LazyVStack(alignment: .leading, spacing: 14) {
      header()
      ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
        TurnRow(
          turn: turn, name: record.displayName(for: turn.speaker),
          color: SpeakerPalette.color(labels.firstIndex(of: turn.speaker) ?? 0),
          isPlaying: canPlay && currentSegment == turn.id,
          isFocused: focusedSegment.map { segment in
            segment >= turn.id && (index + 1 == turns.count || segment < turns[index + 1].id)
          } ?? false,
          jump: canPlay ? { playback.seek(to: turn.start) } : nil,
          edit: record.status == .complete ? edit.map { action in { action(turn.id) } } : nil
        )
        .id(TranscriptTurn.rowID(turn.id))
      }
    }
    .scrollTargetLayout()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Transcript")
  }

}

struct TurnRow: View {
  let turn: TranscriptTurn
  let name: String
  let color: Color
  let isPlaying: Bool
  var isFocused = false
  let jump: (() -> Void)?
  var edit: (() -> Void)?
  @State private var hovering = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      if let jump {
        Button(action: jump) {
          Text(turn.timestamp)
            .font(.callout.monospacedDigit())
        }
        .buttonStyle(.link)
        .accessibilityLabel("Jump to \(Format.spokenDuration(turn.start))")
        .help("Jump to \(turn.timestamp)")
      } else {
        Text(turn.timestamp)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
          Spacer(minLength: 8)

        }
        SelectableTranscriptText(text: turn.text, jump: jump, edit: edit)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(
      color.opacity(isPlaying ? 0.12 : hovering && jump != nil ? 0.055 : 0),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      if isFocused && (jump == nil || isPlaying) {
        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { jump?() }
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(isFocused ? "Linked passage. " : "")\(name) at \(Format.spokenDuration(turn.start)): \(turn.text)"
    )
    .accessibilityAddTraits(isPlaying ? .isSelected : [])
    .accessibilityAction { jump?() }
    .accessibilityAction(named: "Jump to here") { jump?() }
    .accessibilityAction(named: "Edit Text") { edit?() }
    .contextMenu {
      Button("Copy Passage") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.text, forType: .string)
      }
      if let edit { Button("Edit Text…", action: edit) }
      if let jump { Button("Jump to Here", action: jump) }

    }
  }
}

/// A non-modal message above the Library's detail; the model hides it after a few seconds.
struct NoticeBanner: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "info.circle.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 560)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .shadow(radius: 6, y: 2)
    .accessibilityElement(children: .combine)
  }
}

enum SpeakerPalette {
  private static let colors: [Color] = [
    .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red,
  ]

  static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

enum Format {
  static func compactDuration(_ interval: TimeInterval) -> String {
    clock(interval) + (interval >= 3600 ? " h" : " min")
  }

  static func clock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3600 {
      return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  static func duration(_ interval: TimeInterval) -> String {
    Duration.seconds(max(0, interval.rounded())).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
  }

  static func spokenDuration(_ interval: TimeInterval) -> String {
    Duration.seconds(max(0, interval.rounded())).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
  }
}

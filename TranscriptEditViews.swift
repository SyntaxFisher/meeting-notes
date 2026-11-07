import SwiftUI

struct TranscriptEditorSheet: View {
  let model: LibraryModel
  let segment: Int
  @State private var record: MeetingRecord
  @State private var draft: String
  @State private var isSaving = false
  @State private var error: String?
  @State private var showsCurrentText = false
  @FocusState private var textFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(model: LibraryModel, record: MeetingRecord, segment: Int) {
    self.model = model
    self.segment = segment
    _record = State(initialValue: record)
    _draft = State(initialValue: record.segments[segment].text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Edit Text").font(.title3.weight(.semibold))
        Text(
          "\(record.displayName(for: record.segments[segment].speaker)) · \(MeetingLibrary.timestamp(record.segments[segment].start))"
        )
        .foregroundStyle(.secondary)
      }
      if showsCurrentText {
        GroupBox("Current Text") {
          ScrollView {
            Text(record.segments[segment].text)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 110)
          .padding(6)
        }
        Text("Your draft is kept below. Review it before saving.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      TextEditor(text: $draft)
        .font(.body)
        .focused($textFocused)
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary)
        }
        .frame(minHeight: 160, idealHeight: 220, maxHeight: 300)
        .accessibilityLabel("Transcript text")
        .disabled(isSaving)
      Text("Saving replaces this passage in the transcript.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let error {
        EditFailure(message: error, review: reviewLatest)
          .disabled(isSaving)
      }
      HStack {
        if isSaving { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button("Save", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 560)
    .interactiveDismissDisabled(isSaving)
    .task { textFocused = true }
  }

  private func save() {
    isSaving = true
    error = nil
    Task {
      do {
        _ = try await model.saveText(draft, segment: segment, in: record)
        dismiss()
      } catch {
        self.error =
          (error as? MeetingEditConflict)?.userFacingDescription ?? error.localizedDescription
      }
      isSaving = false
    }
  }

  private func reviewLatest() {
    isSaving = true
    Task {
      do {
        let latest = try await model.latestRecord(record.id)
        guard latest.segments.indices.contains(segment) else {
          throw MeetingError("This passage is no longer available.")
        }
        record = latest
        showsCurrentText = true
        error = nil
      } catch {
        self.error =
          (error as? MeetingEditConflict)?.userFacingDescription ?? error.localizedDescription
      }
      isSaving = false
    }
  }
}

struct EditSpeakersSheet: View {
  let model: LibraryModel
  @State private var record: MeetingRecord
  @State private var drafts: [String: String]
  @State private var isSaving = false
  @State private var error: String?
  @State private var pendingMerge: SpeakerMerge?
  @State private var showsMergeConfirmation = false
  @State private var mergeName = ""
  @State private var reviewedLatest = false
  @Environment(\.dismiss) private var dismiss

  private struct SpeakerMerge {
    let source: MeetingSpeaker
    let target: MeetingSpeaker
  }

  init(model: LibraryModel, record: MeetingRecord) {
    self.model = model
    _record = State(initialValue: record)
    _drafts = State(initialValue: Self.names(in: record))
  }

  private static func names(in record: MeetingRecord) -> [String: String] {
    Dictionary(
      record.speakers.map { ($0.label, $0.name ?? "") },
      uniquingKeysWith: { first, _ in
        first
      })
  }

  private var hasNameChanges: Bool {
    record.speakers.contains {
      (drafts[$0.label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != ($0.name ?? "")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Edit Speakers").font(.title3.weight(.semibold))
      Text("Rename speakers or merge duplicate voices.")
        .font(.callout)
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(record.speakers.enumerated()), id: \.element.label) { index, speaker in
            speakerRow(speaker, index: index)
          }
        }
        .padding(.vertical, 4)
      }
      .frame(maxHeight: 360)
      if hasNameChanges {
        Text("Save name changes before merging speakers.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if reviewedLatest {
        Text("Your name drafts were kept. Review them against the current names before saving.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let error {
        EditFailure(message: error, review: reviewLatest).disabled(isSaving)
      }
      HStack {
        if isSaving { ProgressView().controlSize(.small) }
        Spacer()
        Button(hasNameChanges ? "Cancel" : "Done", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        if hasNameChanges {
          Button("Save Names", action: saveNames)
            .keyboardShortcut(.defaultAction)
        }
      }
      .disabled(isSaving)
    }
    .padding(20)
    .frame(width: 520)
    .interactiveDismissDisabled(isSaving)
    .alert("Merge these speakers?", isPresented: $showsMergeConfirmation, presenting: pendingMerge)
    {
      merge in
      TextField("Name", text: $mergeName)
      Button("Merge") { mergeSpeakers(merge) }
      Button("Cancel", role: .cancel) {}
    } message: { merge in
      Text(
        "All turns by \(merge.source.displayName) and \(merge.target.displayName) will belong to one speaker. This cannot be undone."
      )
    }
  }

  private func speakerRow(_ speaker: MeetingSpeaker, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Circle().fill(SpeakerPalette.color(index)).frame(width: 8, height: 8)
          .accessibilityHidden(true)
        TextField(
          "Name",
          text: Binding(
            get: { drafts[speaker.label] ?? "" }, set: { drafts[speaker.label] = $0 }),
          prompt: Text(speaker.label)
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Name for \(speaker.label)")
        .disabled(isSaving)
        if let participants = record.participants?.participants, !participants.isEmpty {
          Menu {
            Section("In Teams") {
              ForEach(Array(Set(participants.map(\.name))).sorted(), id: \.self) { name in
                Button(name) { drafts[speaker.label] = name }
              }
            }
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(isSaving)
          .help("Choose a Teams participant")
          .accessibilityLabel("Teams participants for \(speaker.label)")
        }
        if record.speakers.count > 1 {
          Menu("Merge with…") {
            ForEach(record.speakers.filter { $0.label != speaker.label }, id: \.label) { target in
              Button(speakerChoice(target)) {
                pendingMerge = SpeakerMerge(source: speaker, target: target)
                mergeName = target.name ?? speaker.name ?? ""
                showsMergeConfirmation = true
              }
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(isSaving || hasNameChanges)
          .accessibilityLabel("Merge \(speaker.displayName) with another speaker")
        }
      }
      if reviewedLatest {
        Text("Current name: \(speaker.displayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func speakerChoice(_ speaker: MeetingSpeaker) -> String {
    speaker.name.map { "\($0) (\(speaker.label))" } ?? speaker.label
  }

  private func saveNames() {
    isSaving = true
    error = nil
    Task {
      do {
        record = try await model.saveSpeakerNames(drafts, for: record)
        drafts = Self.names(in: record)
        reviewedLatest = false
      } catch {
        self.error =
          (error as? MeetingEditConflict)?.userFacingDescription ?? error.localizedDescription
      }
      isSaving = false
    }
  }

  private func mergeSpeakers(_ merge: SpeakerMerge) {
    isSaving = true
    error = nil
    Task {
      do {
        record = try await model.mergeSpeakers(
          in: record, keep: merge.target.label, merge: merge.source.label,
          name: TranscriptDocument.cleanedName(mergeName))
        drafts = Self.names(in: record)
        reviewedLatest = false
      } catch {
        self.error =
          (error as? MeetingEditConflict)?.userFacingDescription ?? error.localizedDescription
      }
      isSaving = false
      pendingMerge = nil
    }
  }

  private func reviewLatest() {
    isSaving = true
    Task {
      do {
        let latest = try await model.latestRecord(record.id)
        var keptDrafts = Self.names(in: latest)
        for speaker in latest.speakers {
          if let draft = drafts[speaker.label] { keptDrafts[speaker.label] = draft }
        }
        record = latest
        drafts = keptDrafts
        reviewedLatest = true
        error = nil
      } catch {
        self.error =
          (error as? MeetingEditConflict)?.userFacingDescription ?? error.localizedDescription
      }
      isSaving = false
    }
  }
}

private struct EditFailure: View {
  let message: String
  let review: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message)
        .font(.callout)
        .foregroundStyle(.red)
        .textSelection(.enabled)
      Button("Review Latest Version", action: review)
        .buttonStyle(.link)
    }
    .accessibilityElement(children: .contain)
  }
}

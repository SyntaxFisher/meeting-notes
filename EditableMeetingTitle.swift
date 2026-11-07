import SwiftUI

struct EditableMeetingTitle: View {
  let model: LibraryModel
  let record: MeetingRecord
  let compact: Bool
  @State private var editingRecord: MeetingRecord?
  @State private var draft = ""
  @State private var saving = false
  @State private var error: String?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if editingRecord != nil {
        TextField("Meeting title", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .focused($focused)
          .disabled(saving)
          .onSubmit(save)
          .onExitCommand { cancel() }
        HStack {
          if let error { Text(error).font(.caption).foregroundStyle(.red) }
          Spacer()
          if error != nil {
            Button("Review Latest Version") {
              Task {
                do {
                  editingRecord = try await model.latestRecord(record.id)
                  error = nil
                } catch { self.error = error.localizedDescription }
              }
            }
          }
          Button("Cancel", action: cancel).disabled(saving)
          Button("Save", action: save)
            .disabled(
              saving || error != nil
                || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .font(.callout)
      } else {
        Text(record.displayTitle)
          .lineLimit(compact ? 1 : nil)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture(count: 2, perform: beginEditing)
          .help("Double-click to rename")
          .accessibilityAddTraits(.isHeader)
          .accessibilityAction(named: "Rename Meeting", beginEditing)
      }
    }
    .font(compact ? .headline : .title.weight(.semibold))
  }

  private func beginEditing() {
    guard !record.status.isInProgress else { return }
    editingRecord = record
    draft = record.title ?? ""
    error = nil
    focused = true
  }

  private func cancel() {
    guard !saving else { return }
    editingRecord = nil
    error = nil
    focused = false
  }

  private func save() {
    guard let editingRecord, !saving, error == nil,
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    saving = true
    Task {
      do {
        _ = try await model.saveTitle(draft, for: editingRecord)
        self.editingRecord = nil
        focused = false
      } catch { self.error = error.localizedDescription }
      saving = false
    }
  }
}

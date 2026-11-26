import SwiftUI
import AppKit

/// A task's notes: a field to add one, then the notes newest first, each of which can be edited
/// or deleted. Used in the ticket details and in the editor of a task without a ticket.
struct NotesEditor: View {
    @Binding var notes: [TaskNote]
    /// The tracker's name, for the line that says where notes do not go.
    var tracker: String?
    /// The space's review level: at status only the review leaves the notes out.
    var review: ReviewDetail?

    @State private var draft = ""
    @State private var editing: UUID?
    @State private var deleting: TaskNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                // Return adds; Option-Return makes a new line.
                TextField("Write a note", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(notes.reversed()) { note in
                row(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { note in
            Button("Delete", role: .destructive) {
                notes.removeAll { $0.id == note.id }
                deleting = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { note in
            Text("“\(note.text.prefix(120))”\nThis cannot be undone.")
        }
    }

    // What the line promises is what `ReviewFacts` and `StandupFacts` do: keep the two in step.
    private var caption: String {
        let kept = "Saved only on this Mac and never posted to \(tracker ?? "a tracker")."
        let read = review == .status
            ? " The standup update reads them. The review does not, while this space's review is set to status only."
            : " The review and the standup update read them, so they go to Claude with the task. No other AI feature gets them."
        return kept + read
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.append(TaskNote(text: text))
        draft = ""
    }

    private func text(of note: TaskNote) -> Binding<String> {
        Binding(get: { notes.first { $0.id == note.id }?.text ?? note.text },
                set: { value in
                    // Through a copy, so the binding is written once and the old single note is
                    // turned into a list in the same step.
                    var list = notes
                    guard let i = list.firstIndex(where: { $0.id == note.id }) else { return }
                    list[i].text = value
                    notes = list
                })
    }

    private func finishEditing() {
        // A note emptied while editing is a note deleted.
        notes.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        editing = nil
    }

    private func row(_ note: TaskNote) -> some View {
        let isEditing = editing == note.id
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField("Note", text: text(of: note), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...12)
                        .onSubmit(finishEditing)
                } else {
                    Text(note.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(note.at, format: .dateTime.day().month().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isEditing {
                Button("Done", action: finishEditing).tint(nil)
            } else {
                Button { editing = note.id } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit this note")
                Button { deleting = note } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete this note")
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contextMenu {
            Button("Edit") { editing = note.id }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { deleting = note }
        }
    }
}

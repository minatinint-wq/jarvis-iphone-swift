import SwiftUI

struct ReminderEditor: View {
    @ObservedObject var controller: PhoneController
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var hasDate = false
    @State private var due = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("O que você precisa lembrar?", text: $title, axis: .vertical)
                Toggle("Avisar em uma data", isOn: $hasDate)
                if hasDate { DatePicker("Quando", selection: $due) }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Novo lembrete")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Salvando…" : "Salvar") {
                        saving = true
                        Task {
                            do {
                                try await controller.saveReminder(title: title, due: hasDate ? due : nil)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

struct NoteEditor: View {
    @ObservedObject var controller: PhoneController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                TextEditor(text: $text).padding(12).accessibilityLabel("Texto da nota")
                Text("Você pode usar o ditado do teclado. A nota será salva no JARVIS, neste iPhone.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if let error { Text(error).foregroundStyle(.orange).padding() }
            }
            .navigationTitle("Nova nota")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        do { try controller.saveNote(text: text); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct NotesView: View {
    @ObservedObject var controller: PhoneController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.notes.isEmpty { Text("Você ainda não salvou notas.").foregroundStyle(.secondary) }
                ForEach(controller.notes) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(note.text).textSelection(.enabled)
                        HStack {
                            Text(note.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            ShareLink(item: note.text) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Compartilhar nota")
                        }
                    }.padding(.vertical, 6)
                }.onDelete(perform: controller.deleteNotes)
            }
            .navigationTitle("Minhas notas")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } } }
        }
    }
}

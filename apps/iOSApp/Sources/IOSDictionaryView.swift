import CoreModels
import SwiftUI

/// Custom-dictionary editor (docs/02 FR-i3.2): the same case-insensitive
/// overrides as the Mac, applied to every transcription.
struct IOSDictionaryView: View {
    @ObservedObject var appState: IOSAppState
    @State private var entries: [DictionaryEntry] = []
    @State private var newSpoken = ""
    @State private var newWritten = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Add override") {
                    TextField("Heard as (e.g. cloud code)", text: $newSpoken)
                        .textInputAutocapitalization(.never)
                    TextField("Write as (e.g. Claude Code)", text: $newWritten)
                        .textInputAutocapitalization(.never)
                    Button("Add") { add() }
                        .disabled(
                            newSpoken.trimmingCharacters(in: .whitespaces).isEmpty
                                || newWritten.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
                Section {
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.spoken)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            Text(entry.written).bold()
                            Spacer()
                            if entry.applyCount > 0 {
                                Text("\(entry.applyCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("Overrides")
                } footer: {
                    Text("Matched case-insensitively in every dictation, on both devices once sync lands.")
                }
            }
            .navigationTitle("Dictionary")
            .onAppear { reload() }
        }
    }

    private func reload() {
        guard let database = appState.database else { return }
        entries = (try? database.dictionaryEntries()) ?? []
    }

    private func add() {
        guard let database = appState.database else { return }
        let entry = DictionaryEntry(
            spoken: newSpoken.trimmingCharacters(in: .whitespaces),
            written: newWritten.trimmingCharacters(in: .whitespaces),
            createdAt: Date()
        )
        try? database.save(entry)
        newSpoken = ""
        newWritten = ""
        reload()
    }

    private func delete(at offsets: IndexSet) {
        guard let database = appState.database else { return }
        for index in offsets {
            try? database.deleteDictionaryEntry(id: entries[index].id)
        }
        reload()
    }
}

import CoreModels
import SwiftUI

/// Transcript history with EN + 中文 search (docs/02 FR-i3.1, AC-i9).
struct IOSHistoryView: View {
    @ObservedObject var appState: IOSAppState
    @State private var query = ""
    @State private var records: [TranscriptRecord] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "History unavailable", systemImage: "clock.badge.exclamationmark",
                        description: Text(loadError)
                    )
                } else if records.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No dictations yet" : "No matches",
                        systemImage: "clock"
                    )
                } else {
                    List {
                        ForEach(records) { record in
                            row(record)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("History")
            .searchable(text: $query)
            .onChange(of: query) { _, _ in reload() }
            .onAppear { reload() }
        }
    }

    private func row(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.deliveredText.isEmpty ? record.rawText : record.deliveredText)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(record.createdAt, style: .date)
                Text(record.profileName)
                Text(record.language.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .leading) {
            Button {
                UIPasteboard.general.string =
                    record.deliveredText.isEmpty ? record.rawText : record.deliveredText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
    }

    private func reload() {
        guard let database = appState.database else {
            loadError = "The local database could not be opened."
            return
        }
        do {
            records =
                query.isEmpty
                ? try database.allTranscripts()
                : try database.search(query)
        } catch {
            loadError = String(describing: error)
        }
    }

    private func delete(at offsets: IndexSet) {
        guard let database = appState.database else { return }
        for index in offsets {
            try? database.deleteTranscript(id: records[index].id)
        }
        reload()
    }
}

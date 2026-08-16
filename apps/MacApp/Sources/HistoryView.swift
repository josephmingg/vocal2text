import AppKit
import CoreModels
import PersistenceKit
import SwiftUI

/// Searchable dictation history (FR-5): list of transcripts with a raw vs
/// delivered detail pane. All database work is synchronous GRDB on the main
/// actor — acceptable at personal-history scale; errors degrade to a message,
/// never a crash.
@MainActor
struct HistoryView: View {
    @ObservedObject private var appState: AppState
    @State private var query = ""
    @State private var records: [TranscriptRecord] = []
    @State private var selectedID: UUID?
    @State private var errorText: String?

    init(appState: AppState) {
        _appState = ObservedObject(wrappedValue: appState)
    }

    var body: some View {
        if let database = appState.database {
            content(database: database)
        } else {
            VStack(spacing: 8) {
                Text("History unavailable")
                    .font(.headline)
                Text("The Vocal database could not be opened; dictation still works, but nothing is recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(database: DatabaseStore) -> some View {
        VStack(spacing: 0) {
            TextField("Search history", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            HSplitView {
                List(selection: $selectedID) {
                    if records.isEmpty {
                        Text(query.isEmpty ? "No dictations yet." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        row(record, database: database)
                            .tag(record.id)
                    }
                }
                .frame(minWidth: 320)
                detail
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let errorText {
                Divider()
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
        .onAppear { reload(database: database) }
        .onChange(of: query) { _, _ in reload(database: database) }
    }

    // MARK: - Rows

    private func row(_ record: TranscriptRecord, database: DatabaseStore) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.profileName)
                        .font(.caption)
                        .bold()
                    if !targetAppLabel(record).isEmpty {
                        Text(targetAppLabel(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(record.deliveredText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                delete(record, database: database)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this transcript")
        }
        .padding(.vertical, 2)
    }

    private func targetAppLabel(_ record: TranscriptRecord) -> String {
        if let name = record.targetAppName, !name.isEmpty {
            return name
        }
        return record.targetAppBundleID ?? ""
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let record = records.first(where: { $0.id == selectedID }) {
            HStack(alignment: .top, spacing: 0) {
                transcriptColumn(title: "Raw", text: record.rawText)
                Divider()
                transcriptColumn(title: "Delivered", text: record.deliveredText)
            }
        } else {
            Text("Select a transcript")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcriptColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Copy") { copy(text) }
                    .controlSize(.small)
            }
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Actions

    private func reload(database: DatabaseStore) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                records = try database.allTranscripts()
            } else {
                records = try database.search(trimmed)
            }
            errorText = nil
        } catch {
            records = []
            errorText = "Could not load history: \(error.localizedDescription)"
        }
    }

    private func delete(_ record: TranscriptRecord, database: DatabaseStore) {
        do {
            try database.deleteTranscript(id: record.id)
            if selectedID == record.id {
                selectedID = nil
            }
            reload(database: database)
        } catch {
            errorText = "Could not delete transcript: \(error.localizedDescription)"
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

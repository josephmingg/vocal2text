import AVFoundation
import AppKit
import AudioPipeline
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
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

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
        .onChange(of: selectedID) { _, _ in
            player?.stop()
            player = nil
            isPlaying = false
        }
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
            VStack(spacing: 0) {
                if let audioURL = playableAudioURL(for: record) {
                    audioRow(url: audioURL)
                    Divider()
                }
                HStack(alignment: .top, spacing: 0) {
                    transcriptColumn(title: "Raw", text: record.rawText)
                    Divider()
                    transcriptColumn(title: "Delivered", text: record.deliveredText)
                }
            }
        } else {
            Text("Select a transcript")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The take's recording, when it was kept and is still on disk. Checked
    /// rather than trusted: the retention sweep can remove a file while the
    /// row still points at it (docs/11 G9).
    private func playableAudioURL(for record: TranscriptRecord) -> URL? {
        guard let path = record.audioPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func audioRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Button {
                play(url)
            } label: {
                Label(
                    isPlaying ? "Stop" : "Play recording",
                    systemImage: isPlaying ? "stop.fill" : "play.fill"
                )
            }
            .controlSize(.small)
            Text("What you actually said")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
    }

    private func play(_ url: URL) {
        if isPlaying {
            player?.stop()
            player = nil
            isPlaying = false
            return
        }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.play()
            player = newPlayer
            isPlaying = true
            // No delegate plumbing for a few seconds of speech: the button
            // returns to "Play" once the clip is over.
            let duration = newPlayer.duration
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration))
                if player === newPlayer {
                    isPlaying = false
                    player = nil
                }
            }
        } catch {
            errorText = "Could not play recording: \(error.localizedDescription)"
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
            // The recording is part of the transcript, not a separate thing to
            // clean up later (docs/11 G9).
            if let directory = AppState.audioDirectory() {
                AudioArchive.delete(forTranscript: record.id, in: directory)
            }
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

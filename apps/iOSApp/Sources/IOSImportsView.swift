import BridgeKit
import SwiftUI

/// The share-sheet import queue (docs/02 FR-i2.3, FR-i3.5): what arrived, what
/// is being transcribed right now, and what failed and why.
struct IOSImportsView: View {
    @ObservedObject var processor: ImportProcessor

    var body: some View {
        List {
            if processor.isRunning, let active = processor.active {
                Section("Transcribing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(active.originalFilename).lineLimit(1)
                        ProgressView(value: processor.progress)
                        Button("Cancel", role: .cancel) { processor.cancel() }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let error = processor.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if processor.items.isEmpty {
                Section {
                    Text("Nothing waiting. Share a voice note to Vocal from any app.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Queue") {
                    ForEach(processor.items) { item in
                        row(item)
                    }
                }
            }
        }
        .navigationTitle("Voice notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Transcribe all") { processor.processPending() }
                    .disabled(processor.isRunning || processor.items.allSatisfy(\.isExhausted))
            }
        }
        .onAppear { processor.refresh() }
    }

    private func row(_ item: ImportManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.originalFilename).lineLimit(1)
            HStack(spacing: 8) {
                Text(item.receivedAt, style: .date)
                Text(Self.sizeText(item.byteCount))
                if let error = item.lastError {
                    Text(error).foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { processor.delete(item) }
            if item.isExhausted {
                Button("Retry") { processor.retry(item) }.tint(.blue)
            }
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

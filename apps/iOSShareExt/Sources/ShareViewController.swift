import BridgeKit
import UIKit
import UniformTypeIdentifiers

/// Share-sheet import (docs/02 FR-i2.3, D3): takes voice notes from WhatsApp,
/// Voice Memos, Messages, Files — anything that offers an audio attachment —
/// and drops them in Vocal's inbox for the app to transcribe.
///
/// It deliberately does no transcription of its own. A share extension has a
/// tight memory budget and can be killed the moment the sheet dismisses, so
/// the only job here is to get the bytes across the App Group boundary and
/// commit a manifest. `ImportInbox` makes that crash-safe: audio is copied
/// first, the manifest second, and a manifest is what makes an item real.
final class ShareViewController: UIViewController {

    private let inbox = ImportInbox.appGroup()
    private let statusLabel = UILabel()
    private var remaining = 0
    private var accepted = 0
    private var rejected = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        installUI()
        ingestAttachments()
    }

    // MARK: - UI

    private func installUI() {
        view.backgroundColor = .systemBackground
        statusLabel.text = "Saving to Vocal…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Intake

    private func ingestAttachments() {
        guard let inbox else {
            finish(message: "Vocal's shared storage is unavailable. Open Vocal once, then retry.")
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let importable: [(provider: NSItemProvider, typeID: String, name: String)] =
            providers.compactMap { provider in
                guard let typeID = Self.audioTypeIdentifier(in: provider) else { return nil }
                let name = provider.suggestedName ?? Self.fallbackName(for: typeID)
                return (provider, typeID, name)
            }

        guard !importable.isEmpty else {
            finish(message: "No audio found in what you shared.")
            return
        }

        remaining = importable.count
        for (provider, typeID, name) in importable {
            // Only `inbox` (a Sendable value), the name, and a weak reference
            // to this controller cross into the completion handler.
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, _ in
                var succeeded = false
                if let url {
                    // The provider's URL is valid only for the duration of this
                    // callback, so the copy has to happen here and now.
                    succeeded = ((try? inbox.accept(contentsOf: url, originalFilename: name)) != nil)
                }
                let outcome = succeeded
                Task { @MainActor in
                    self?.noteOutcome(succeeded: outcome)
                }
            }
        }
    }

    @MainActor
    private func noteOutcome(succeeded: Bool) {
        if succeeded { accepted += 1 } else { rejected += 1 }
        remaining -= 1
        guard remaining == 0 else { return }

        if accepted > 0 {
            #if canImport(Darwin)
            // Nudge the app if it happens to be alive; otherwise it picks the
            // inbox up on next launch.
            DarwinSignalCenter.shared.post(.statusChanged)
            #endif
        }
        finish(message: Self.summary(accepted: accepted, rejected: rejected))
    }

    // MARK: - Completion

    private func finish(message: String) {
        statusLabel.text = message
        // Long enough to read, short enough not to feel stuck.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.extensionContext?.completeRequest(returningItems: [])
        }
    }

    // MARK: - Helpers

    /// The first registered type that is actually audio — providers usually
    /// advertise several, and the audio one is the one worth reading.
    static func audioTypeIdentifier(in provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .audio)
        }
    }

    static func fallbackName(for typeID: String) -> String {
        let ext = UTType(typeID)?.preferredFilenameExtension ?? "m4a"
        return "Voice note.\(ext)"
    }

    static func summary(accepted: Int, rejected: Int) -> String {
        switch (accepted, rejected) {
        case (0, _):
            "Could not read that audio."
        case (let count, 0):
            count == 1 ? "Saved to Vocal." : "Saved \(count) notes to Vocal."
        case (let count, let failed):
            "Saved \(count); \(failed) could not be read."
        }
    }
}

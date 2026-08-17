import AppKit
import Foundation

/// Full-fidelity pasteboard snapshot/restore for paste-insertion
/// (docs/03 §3.2 tier 1, FR-3.5; pattern from VoiceInk's ClipboardService,
/// docs/09): capture every `NSPasteboardItem` and every type's data before we
/// clobber the pasteboard, and put it all back afterwards — unless the user
/// copied something new in the meantime.
@MainActor
final class ClipboardManager {

    /// Everything the general pasteboard held: one dictionary per
    /// `NSPasteboardItem`, keyed by raw UTI, so images/RTF/file URLs survive
    /// the round-trip (FR-3.5).
    struct Snapshot {
        var items: [[String: Data]]
    }

    private let pasteboard = NSPasteboard.general

    func snapshot() -> Snapshot {
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var typedData: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                typedData[type.rawValue] = data
            }
            items.append(typedData)
        }
        return Snapshot(items: items)
    }

    /// Write the transcript, marked transient + concealed so clipboard
    /// managers ignore it and never log dictated text (docs/03 §3.2; the
    /// org.nspasteboard.* convention).
    func write(_ text: String) {
        let item = NSPasteboardItem()
        _ = item.setData(Data(), forType: NSPasteboard.PasteboardType(Self.transientType))
        _ = item.setData(Data(), forType: NSPasteboard.PasteboardType(Self.concealedType))
        _ = item.setString(text, forType: .string)
        _ = pasteboard.clearContents()
        _ = pasteboard.writeObjects([item])
    }

    /// Restore the snapshot only if the pasteboard still holds our transcript.
    /// If the current string differs, the user (or an app) copied something
    /// new during the paste window — restoring would clobber it (docs/09:
    /// "restore refuses if pasteboard string ≠ what we pasted").
    func restore(_ snapshot: Snapshot, ifPasteboardStillHolds expectedText: String) {
        guard pasteboard.string(forType: .string) == expectedText else { return }
        _ = pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        var restored: [NSPasteboardItem] = []
        for typedData in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in typedData {
                _ = item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            restored.append(item)
        }
        _ = pasteboard.writeObjects(restored)
    }

    // MARK: - Pasteboard-marker UTIs (nspasteboard.org convention)

    private static let transientType = "org.nspasteboard.TransientType"
    private static let concealedType = "org.nspasteboard.ConcealedType"
}

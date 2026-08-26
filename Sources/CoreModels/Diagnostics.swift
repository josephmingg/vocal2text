import Foundation

#if canImport(os)
import os

/// Structured loggers, one per subsystem area (NFR-1: os_log with privacy in
/// mind — operational strings only, never transcript text or audio). All call
/// sites live in Apple-only code; Linux builds simply have no callers.
public enum VocalLog {
    private static let subsystem = "com.vocal.app"

    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    public static let delivery = Logger(subsystem: subsystem, category: "delivery")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
#endif

/// Monotonic counters for the failure modes worth watching (docs/07 R5 names
/// validator rejections the early-warning signal; paste fallbacks and tap
/// re-enables are the other silent degradations). Persisted in UserDefaults —
/// diagnostics, not history — and shown in Settings → About.
public final class Diagnostics: @unchecked Sendable {

    public enum Counter: String, CaseIterable, Sendable {
        case cleanupValidatorRejections
        case cleanupFailures
        case transcriptionFailures
        case clipboardFallbacks
        case secureFieldBlocks
        case hotkeyTapReenables

        public var label: String {
            switch self {
            case .cleanupValidatorRejections: return "Cleanup rejected by validator"
            case .cleanupFailures: return "Cleanup provider failures"
            case .transcriptionFailures: return "Transcription failures"
            case .clipboardFallbacks: return "Clipboard fallbacks"
            case .secureFieldBlocks: return "Secure-field blocks"
            case .hotkeyTapReenables: return "Hotkey tap re-enables"
            }
        }
    }

    public static let shared = Diagnostics()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var counts: [Counter: Int]

    /// `defaults` is injectable so tests never touch the standard domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [Counter: Int] = [:]
        for counter in Counter.allCases {
            loaded[counter] = defaults.integer(forKey: Self.key(for: counter))
        }
        self.counts = loaded
    }

    public func increment(_ counter: Counter) {
        lock.lock()
        let next = (counts[counter] ?? 0) + 1
        counts[counter] = next
        lock.unlock()
        defaults.set(next, forKey: Self.key(for: counter))
    }

    public func count(of counter: Counter) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[counter] ?? 0
    }

    /// All counters in declaration order, for display.
    public func snapshot() -> [(counter: Counter, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return Counter.allCases.map { ($0, counts[$0] ?? 0) }
    }

    public func reset() {
        lock.lock()
        counts = [:]
        lock.unlock()
        for counter in Counter.allCases {
            defaults.removeObject(forKey: Self.key(for: counter))
        }
    }

    private static func key(for counter: Counter) -> String {
        "diagnostics.\(counter.rawValue)"
    }
}

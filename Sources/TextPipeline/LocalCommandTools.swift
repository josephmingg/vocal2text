import Foundation

/// Deterministic, offline answers for the command mode's everyday questions
/// (docs/17 G4.3, after Glaido's "math and dates" tool): arithmetic and the
/// date or time. Exact where a 3B model is not, instant, and no model needed.
/// Anything not recognised returns nil and goes to the model.
public enum LocalCommandTools {

    public static func answer(
        _ instruction: String,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let text = normalized(instruction)
        guard !text.isEmpty else { return nil }
        if let date = dateAnswer(text, now: now, locale: locale, timeZone: timeZone) {
            return date
        }
        return arithmeticAnswer(text)
    }

    /// Lowercased, "what's"/"what is"/"calculate"-style lead-ins and a final
    /// question mark or full stop removed, whitespace collapsed.
    static func normalized(_ instruction: String) -> String {
        var text = instruction.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, "?.!".contains(last) {
            text.removeLast()
        }
        for lead in [
            "what's", "what is", "whats", "calculate", "compute", "how much is", "tell me",
        ] where text.hasPrefix(lead + " ") {
            text = String(text.dropFirst(lead.count + 1))
            break
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Date and time

    private static func dateAnswer(
        _ text: String, now: Date, locale: Locale, timeZone: TimeZone
    ) -> String? {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch text {
        case "the date", "the date today", "today's date", "the day today", "today",
            "the date it is", "date":
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return formatter.string(from: now)
        case "the day", "the day it is", "day is it", "day is it today", "what day is it",
            "what day is it today":
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: now)
        case "the time", "the time now", "time is it", "time", "what time is it",
            "the current time":
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: now)
        default:
            break
        }
        // "what day is it" arrives without its lead-in stripped.
        if text.hasPrefix("what day is it") {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: now)
        }
        if text.hasPrefix("what time is it") {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: now)
        }
        return nil
    }

    // MARK: - Arithmetic

    private static let number = "(-?\\d[\\d,]*(?:\\.\\d+)?)"

    /// "15% of 240", "15 percent of 240", "12 times 7", "12 x 7", "12 * 7",
    /// "250 divided by 4", "250 / 4", "3 plus 4", "3 + 4", "10 minus 4",
    /// "10 - 4", "2 to the power of 8". Two operands only — a chain is the
    /// model's job, and a wrong exact-looking number is worse than none.
    static func arithmeticAnswer(_ text: String) -> String? {
        let operations: [(pattern: String, apply: (Double, Double) -> Double?)] = [
            ("\(number)\\s*(?:%|percent)\\s+of\\s+\(number)", { $0 / 100 * $1 }),
            ("\(number)\\s+(?:times|multiplied by|x|\\*|×)\\s+\(number)", { $0 * $1 }),
            ("\(number)\\s*(?:divided by|over|/|÷)\\s*\(number)", { $1 == 0 ? nil : $0 / $1 }),
            ("\(number)\\s*(?:plus|\\+)\\s*\(number)", { $0 + $1 }),
            ("\(number)\\s+(?:minus|-|less)\\s+\(number)", { $0 - $1 }),
            ("\(number)\\s+(?:to the power of|to the)\\s+\(number)", { pow($0, $1) }),
        ]
        for operation in operations {
            guard
                let regex = try? NSRegularExpression(pattern: "^" + operation.pattern + "$")
            else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                let left = Range(match.range(at: 1), in: text).flatMap({ parse(text[$0]) }),
                let right = Range(match.range(at: 2), in: text).flatMap({ parse(text[$0]) }),
                let value = operation.apply(left, right),
                value.isFinite
            else { continue }
            return format(value)
        }
        return nil
    }

    private static func parse(_ token: Substring) -> Double? {
        Double(token.replacingOccurrences(of: ",", with: ""))
    }

    /// Integers without a decimal point; otherwise up to six decimals with
    /// trailing zeros trimmed. No grouping separators: the result is meant
    /// to be pasted into whatever field the user is in.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

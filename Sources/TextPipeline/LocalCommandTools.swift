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

    private static let dateQuestions: Set<String> = [
        "the date", "today's date", "today", "the date it is", "date", "the day today",
    ]
    private static let dayQuestions: Set<String> = [
        "the day", "the day it is", "day is it", "what day is it", "day of the week",
        "the day of the week", "what day of the week is it",
    ]
    private static let timeQuestions: Set<String> = [
        "the time", "time is it", "time", "what time is it", "the current time",
    ]

    /// Only the plain question, optionally ending "now" / "right now" /
    /// "today". "What time is it in Tokyo?" and "what day is it tomorrow?"
    /// must not get the local answer — they go to the model, which can say
    /// it does not know rather than give a confidently wrong time.
    private static func dateAnswer(
        _ text: String, now: Date, locale: Locale, timeZone: TimeZone
    ) -> String? {
        var question = text
        for suffix in [" right now", " now", " today"] where question.hasSuffix(suffix) {
            question = String(question.dropLast(suffix.count))
            break
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if dateQuestions.contains(question) {
            formatter.dateStyle = .full
            formatter.timeStyle = .none
        } else if dayQuestions.contains(question) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if timeQuestions.contains(question) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            return nil
        }
        return formatter.string(from: now)
    }

    // MARK: - Arithmetic

    /// A plain number or one with correct thousands groups ("1,000,000") —
    /// "1,2" is not a number, and reading it as 12 would be a wrong answer.
    private static let number = "(-?(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d+)?)"

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
        // Past 15 digits a Double no longer holds every digit; printing them
        // all would show hundreds of exact-looking but invented digits.
        // Below a millionth, six decimals would print a confident "0".
        if abs(value) >= 1e15 || abs(value) < 1e-6 {
            return String(value)
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

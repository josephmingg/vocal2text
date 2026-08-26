import Foundation

/// Deterministic spoken-number formatting for English (docs/15 step 51):
/// "twenty twenty six" → "2026", "three thirty pm" → "3:30 pm",
/// "fifty percent" → "50%". Faster and more reliable than asking a 3B model
/// to do arithmetic, and it runs even when cleanup is off.
///
/// Conservative on purpose — every pattern requires an unambiguous anchor
/// (a meridiem, the word "percent", a two-part year shape), because a wrong
/// conversion in delivered text is worse than a spelled-out number. Runs in
/// stage 4 gated on `autoPunctuation`, so verbatim profiles keep the
/// speaker's words untouched.
public enum SpokenNumberFormatter {

    public static func apply(_ text: String) -> String {
        var result = text
        result = replacingTimes(result)
        result = replacingYears(result)
        result = replacingPercents(result)
        return result
    }

    // MARK: - Vocabulary

    private static let unitValues: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teenValues: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tenValues: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let unitPattern = "one|two|three|four|five|six|seven|eight|nine"
    private static let teenPattern =
        "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
    private static let tenPattern = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"

    /// 0–99 from "seven", "fifteen", "twenty five", "twenty-five", "zero".
    static func smallNumber(_ phrase: String) -> Int? {
        let words = phrase.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(String.init)
        switch words.count {
        case 1:
            let word = words[0]
            if word == "zero" { return 0 }
            return unitValues[word] ?? teenValues[word] ?? tenValues[word]
        case 2:
            guard let tens = tenValues[words[0]], let unit = unitValues[words[1]] else {
                return nil
            }
            return tens + unit
        default:
            return nil
        }
    }

    // MARK: - Times

    /// Hour word 1–12; minutes require an explicit spoken form; the meridiem
    /// is the disambiguating anchor. Hour-only times additionally require a
    /// time preposition, because "which one am I" contains "one am".
    private static let hourPattern = "(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
    private static let minutePattern =
        "(oh (?:\(unitPattern))|(?:twenty|thirty|forty|fifty)(?:[ -](?:\(unitPattern)))?|ten|fifteen)"
    private static let meridiemPattern = "(a\\.m\\.|p\\.m\\.|am\\b|pm\\b)"

    private static func replacingTimes(_ text: String) -> String {
        var result = replacing(
            pattern: "\\b\(hourPattern) \(minutePattern) \(meridiemPattern)",
            in: text
        ) { groups in
            guard
                let hour = groups[1].flatMap(smallNumber),
                let minuteText = groups[2],
                let meridiem = groups[3]
            else { return nil }
            let minutes: Int?
            if minuteText.lowercased().hasPrefix("oh ") {
                minutes = smallNumber(String(minuteText.dropFirst(3)))
            } else {
                minutes = smallNumber(minuteText)
            }
            guard let minutes else { return nil }
            return "\(hour):" + String(format: "%02d", minutes) + " \(meridiem)"
        }
        result = replacing(
            pattern: "\\b(at|by|before|after|around|until|till) \(hourPattern) \(meridiemPattern)",
            in: result
        ) { groups in
            guard
                let preposition = groups[1],
                let hour = groups[2].flatMap(smallNumber),
                let meridiem = groups[3]
            else { return nil }
            return "\(preposition) \(hour) \(meridiem)"
        }
        return result
    }

    // MARK: - Years

    private static func replacingYears(_ text: String) -> String {
        var result = replacing(
            // "twenty ten" … "twenty nineteen", "twenty twenty" …
            // "twenty twenty nine". "twenty twenty vision" stays words.
            pattern:
                "\\btwenty (\(teenPattern)|twenty(?:[ -](?:\(unitPattern)))?)\\b(?! vision)",
            in: text
        ) { groups in
            guard let part = groups[1].flatMap(smallNumber) else { return nil }
            return String(2000 + part)
        }
        result = replacing(
            // "nineteen ninety five" → 1995; the two-part shape is the anchor.
            pattern:
                "\\bnineteen ((?:\(tenPattern))(?:[ -](?:\(unitPattern)))?)\\b",
            in: result
        ) { groups in
            guard let part = groups[1].flatMap(smallNumber) else { return nil }
            return String(1900 + part)
        }
        result = replacing(
            // "two thousand and five" / "two thousand twenty four" — but never
            // "two thousand five hundred", which is a quantity mid-phrase.
            pattern:
                "\\btwo thousand (?:and )?((?:\(tenPattern))(?:[ -](?:\(unitPattern)))?|\(teenPattern)|\(unitPattern))\\b(?! (?:hundred|thousand|million|billion))",
            in: result
        ) { groups in
            guard let part = groups[1].flatMap(smallNumber) else { return nil }
            return String(2000 + part)
        }
        return result
    }

    // MARK: - Percent

    private static func replacingPercents(_ text: String) -> String {
        replacing(
            pattern:
                "\\b(zero|(?:\(tenPattern))(?:[ -](?:\(unitPattern)))?|\(teenPattern)|\(unitPattern)|(?:one|a) hundred) percent\\b",
            in: text
        ) { groups in
            guard let phrase = groups[1] else { return nil }
            let lowered = phrase.lowercased()
            let value = lowered.hasSuffix("hundred") ? 100 : smallNumber(phrase)
            guard let value else { return nil }
            return "\(value)%"
        }
    }

    // MARK: - Regex plumbing

    /// Case-insensitive replace-all with a computed replacement. `groups[i]`
    /// is capture i's text (0 = whole match); a nil return keeps the match.
    private static func replacing(
        pattern: String,
        in text: String,
        transform: ([String?]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var groups: [String?] = []
            for index in 0..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) {
                    groups.append(String(text[range]))
                } else {
                    groups.append(nil)
                }
            }
            result += text[cursor..<matchRange.lowerBound]
            result += transform(groups) ?? String(text[matchRange])
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }
}

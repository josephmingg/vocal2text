import Foundation

/// Expands the tags a snippet's written form may carry (docs/17 F5, after
/// Glaido): `{date}`, `{time}` and `{clipboard}`. Tags match
/// case-insensitively; anything else in braces is left exactly as written,
/// so a snippet holding code (`func f() {}`) survives untouched.
public enum SnippetTemplate {

    /// True when expanding `template` needs the clipboard — callers read the
    /// pasteboard only then, never for an ordinary snippet.
    public static func needsClipboard(_ template: String) -> Bool {
        template.range(of: "{clipboard}", options: .caseInsensitive) != nil
    }

    /// `clipboard` nil (or unavailable) expands to an empty string rather
    /// than leaving the tag in the delivered text.
    public static func expand(
        _ template: String,
        clipboard: String?,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard template.contains("{") else { return template }
        var result = template
        result = replacingTag("date", in: result) {
            format(now, date: .long, time: .none, locale: locale, timeZone: timeZone)
        }
        result = replacingTag("time", in: result) {
            format(now, date: .none, time: .short, locale: locale, timeZone: timeZone)
        }
        result = replacingTag("clipboard", in: result) { clipboard ?? "" }
        return result
    }

    private static func replacingTag(
        _ name: String, in text: String, value: () -> String
    ) -> String {
        let tag = "{\(name)}"
        guard text.range(of: tag, options: .caseInsensitive) != nil else { return text }
        let replacement = value()
        var result = ""
        var remainder = text[...]
        while let range = remainder.range(of: tag, options: .caseInsensitive) {
            result += remainder[..<range.lowerBound]
            result += replacement
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }

    private static func format(
        _ date: Date,
        date dateStyle: DateFormatter.Style,
        time timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}

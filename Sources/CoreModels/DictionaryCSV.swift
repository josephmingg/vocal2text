import Foundation

/// CSV import/export for dictionary entries and snippets together (docs/15
/// step 26) — a snippet is simply an entry whose written form spans lines,
/// so one format carries both. RFC-4180 quoting: fields containing commas,
/// quotes, or newlines are quoted, quotes double, and quoted fields may
/// contain newlines (that's what makes multi-line snippets survive the
/// round trip). Pure and Linux-tested.
public enum DictionaryCSV {

    public static let header = "spoken,written,enabled"

    // MARK: - Export

    public static func export(_ entries: [DictionaryEntry]) -> String {
        var lines = [header]
        for entry in entries {
            lines.append(
                [
                    escaped(entry.spoken),
                    escaped(entry.written),
                    entry.isEnabled ? "true" : "false",
                ].joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Import

    /// Parsed rows, in file order. Rows with an empty spoken or written form
    /// are skipped; a header row (exact or case-insensitive match) is skipped;
    /// a missing `enabled` column defaults to true. Returns [] for text that
    /// is not usable CSV rather than throwing — the caller reports "nothing
    /// imported".
    public static func parse(_ text: String) -> [DictionaryEntry] {
        let rows = parseRows(text)
        var entries: [DictionaryEntry] = []
        for (index, row) in rows.enumerated() {
            guard row.count >= 2 else { continue }
            let spoken = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let written = row[1]
            if index == 0, spoken.lowercased() == "spoken" { continue }
            guard !spoken.isEmpty, !written.isEmpty else { continue }
            let enabled: Bool
            if row.count >= 3 {
                enabled = ["true", "1", "yes", ""].contains(
                    row[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            } else {
                enabled = true
            }
            entries.append(
                DictionaryEntry(spoken: spoken, written: written, isEnabled: enabled)
            )
        }
        return entries
    }

    /// RFC-4180 row splitter: handles quoted fields (with embedded commas,
    /// escaped quotes, and newlines), \n, \r\n, and bare-\r row endings, and
    /// a UTF-8 BOM (Excel's "CSV UTF-8" prepends one).
    static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var index = 0
        // A trailing newline closes the last row cleanly — but only when the
        // parser will actually see it as one: appended inside an unterminated
        // quote it would be swallowed into the field, so that case is handled
        // by the explicit flush after the loop instead.
        var syntheticNewline = false
        if characters.last != "\n" {
            characters.append("\n")
            syntheticNewline = true
        }
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else if character == "\r\n" || character == "\r" {
                    // Quoted multi-line fields normalize to \n — written
                    // forms should never paste carriage returns.
                    field.append("\n")
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                // "\r\n" is a single Character (one grapheme cluster) in
                // Swift, so a CRLF row ending never matches "\r" or "\n"
                // alone — it must be listed itself or it lands in `default`
                // and corrupts the field (the exact bug CI caught). A bare
                // \r (classic-Mac endings) also terminates the row; dropping
                // it would concatenate adjacent rows' fields.
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r", "\r\n":
                    row.append(field)
                    field = ""
                    if !(row.count == 1 && row[0].isEmpty) {
                        rows.append(row)
                    }
                    row = []
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        // An unterminated quote at EOF must not silently discard what was
        // read into it — flush the pending row so a one-character typo in a
        // hand-edited file loses at most its quoting, not its data.
        if !field.isEmpty || !row.isEmpty {
            // The newline this parser appended itself is not user data.
            if inQuotes, syntheticNewline, field.hasSuffix("\n") { field.removeLast() }
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        }
        return rows
    }
}

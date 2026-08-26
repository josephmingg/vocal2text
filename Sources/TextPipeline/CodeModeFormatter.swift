import Foundation

/// Code mode (docs/15 step 31): spoken symbols and casing commands become
/// code. "snake case user name equals five" → "user_name = five",
/// "get value open paren close paren" → "get value()". Deterministic and
/// profile-gated — it runs only where a Terminal/Code profile opted in, so
/// prose dictation never sees it.
public enum CodeModeFormatter {

    /// Two-word spoken symbols, checked before the single-word table.
    static let twoWordSymbols: [String: String] = [
        "open paren": "(", "close paren": ")",
        "open bracket": "[", "close bracket": "]",
        "open brace": "{", "close brace": "}",
        "open angle": "<", "close angle": ">",
        "fat arrow": "=>",
        "double equals": "==",
        "not equals": "!=",
        "plus equals": "+=",
    ]

    static let oneWordSymbols: [String: String] = [
        "arrow": "->",
        "equals": "=",
        "underscore": "_",
        "dash": "-",
        "dot": ".",
        "colon": ":",
        "semicolon": ";",
        "comma": ",",
        "ampersand": "&",
        "pipe": "|",
        "backslash": "\\",
        "slash": "/",
        "asterisk": "*",
        "percent": "%",
        "tilde": "~",
    ]

    /// Casing commands consume the identifier words that follow, up to the
    /// next symbol keyword or non-letter token.
    enum Casing: String {
        case camel = "camel"
        case pascal = "pascal"
        case snake = "snake"
        case constant = "constant"
        case kebab = "kebab"

        func join(_ words: [String]) -> String {
            let lowered = words.map { $0.lowercased() }
            switch self {
            case .camel:
                guard let first = lowered.first else { return "" }
                return first + lowered.dropFirst().map(\.capitalized).joined()
            case .pascal:
                return lowered.map(\.capitalized).joined()
            case .snake:
                return lowered.joined(separator: "_")
            case .constant:
                return lowered.map { $0.uppercased() }.joined(separator: "_")
            case .kebab:
                return lowered.joined(separator: "-")
            }
        }
    }

    public static func apply(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return text }

        var output: [String] = []
        var index = 0
        while index < tokens.count {
            let word = tokens[index].lowercased()

            // Casing command: "<casing> case a b c" — consume identifier words.
            if index + 1 < tokens.count,
                tokens[index + 1].lowercased() == "case",
                let casing = Casing(rawValue: word) {
                var identifier: [String] = []
                var next = index + 2
                while next < tokens.count, isIdentifierWord(tokens[next]),
                    !isSymbolKeyword(at: next, in: tokens) {
                    identifier.append(tokens[next])
                    next += 1
                }
                if identifier.isEmpty {
                    output.append(tokens[index])
                    index += 1
                } else {
                    output.append(casing.join(identifier))
                    index = next
                }
                continue
            }

            // Two-word symbol.
            if index + 1 < tokens.count {
                let pair = word + " " + tokens[index + 1].lowercased()
                if let symbol = twoWordSymbols[pair] {
                    output.append(symbol)
                    index += 2
                    continue
                }
            }

            // One-word symbol.
            if let symbol = oneWordSymbols[word] {
                output.append(symbol)
                index += 1
                continue
            }

            output.append(tokens[index])
            index += 1
        }

        return tightened(output.joined(separator: " "))
    }

    private static func isSymbolKeyword(at index: Int, in tokens: [String]) -> Bool {
        let word = tokens[index].lowercased()
        if oneWordSymbols[word] != nil { return true }
        if index + 1 < tokens.count,
            twoWordSymbols[word + " " + tokens[index + 1].lowercased()] != nil {
            return true
        }
        // A later "snake case" etc. also ends the current identifier.
        if index + 1 < tokens.count,
            tokens[index + 1].lowercased() == "case",
            Casing(rawValue: word) != nil {
            return true
        }
        return false
    }

    private static func isIdentifierWord(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Code-shaped spacing: nothing before closers and separators, nothing
    /// after openers, openers glue to the identifier they follow (calls and
    /// indexing), dots and underscores glue their neighbors. An opener after
    /// an operator keeps its space — "-> (value)".
    static func tightened(_ text: String) -> String {
        var result = text
        result = PipelineRegex.replacing(pattern: " +([)\\]}>,;:])", in: result, with: "$1")
        result = PipelineRegex.replacing(pattern: "([(\\[{<]) +", in: result, with: "$1")
        result = PipelineRegex.replacing(pattern: "(\\w) +([(\\[])", in: result, with: "$1$2")
        result = PipelineRegex.replacing(pattern: " *([._]) *", in: result, with: "$1")
        return result
    }
}

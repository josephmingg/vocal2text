import Foundation

/// Loads eval cases from a directory of JSON files.
///
/// One file per category rather than one big array: a failing category is then
/// a small diff, and adding cases does not churn a 60-entry file.
public enum EvalCaseLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case noCases(String)
        case duplicateIDs([String])
        case decoding(file: String, underlying: String)

        public var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "Cannot read eval directory: \(path)"
            case .noCases(let path):
                return "No .json case files in \(path)"
            case .duplicateIDs(let ids):
                // IDs key the report and the diff; duplicates would silently
                // overwrite each other's results.
                return "Duplicate case IDs: \(ids.joined(separator: ", "))"
            case .decoding(let file, let underlying):
                return "\(file): \(underlying)"
            }
        }
    }

    public static func load(directory: String) throws -> [EvalCase] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else {
            throw LoadError.directoryUnreadable(directory)
        }

        let files = entries.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw LoadError.noCases(directory)
        }

        let decoder = JSONDecoder()
        var cases: [EvalCase] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                cases.append(contentsOf: try decoder.decode([EvalCase].self, from: data))
            } catch {
                throw LoadError.decoding(
                    file: file.lastPathComponent, underlying: String(describing: error)
                )
            }
        }

        let duplicates = Dictionary(grouping: cases, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        guard duplicates.isEmpty else {
            throw LoadError.duplicateIDs(duplicates)
        }
        return cases
    }
}

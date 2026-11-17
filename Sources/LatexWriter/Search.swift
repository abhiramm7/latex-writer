import Foundation

struct SearchHit: Identifiable {
    let id = UUID()
    var file: URL
    var line: Int
    var snippet: String
}

/// Plain-text, case-sensitive search and replace across a project's files.
/// Case matters in LaTeX: replacing "Section" must not touch "\section".
enum Search {
    static func find(_ query: String, in text: String, file: URL) -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains(query) {
            hits.append(SearchHit(file: file, line: i + 1, snippet: line.trimmingCharacters(in: .whitespaces)))
        }
        return hits
    }

    /// Returns the new text and how many occurrences were replaced.
    static func replace(_ query: String, with replacement: String, in text: String) -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        return (text.replacingOccurrences(of: query, with: replacement), text.components(separatedBy: query).count - 1)
    }
}

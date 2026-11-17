import Foundation

struct OutlineItem: Identifiable {
    let id = UUID()
    var title: String
    var level: Int
    var line: Int
    var file: URL?
}

/// What one pass over a document collects: sections, TODOs and labels, in reading order.
struct ProjectScan {
    var sections: [OutlineItem] = []
    var todos: [OutlineItem] = []
    var labels: [String] = []
    var visited: Set<URL> = []
}

enum Outline {
    private static let levels = ["part": 0, "chapter": 0, "section": 0, "subsection": 1, "subsubsection": 2]

    /// Walks a document in reading order, following \input, \include and \subfile.
    /// `read` supplies each file's text, so the editor's unsaved text can stand in for the file on disk.
    // shortcut: line-based regexes, so a title with nested braces is cut at the first "}"
    static func scan(_ file: URL, base: URL, read: (URL) -> String?, into scan: inout ProjectScan, depth: Int = 0) {
        let file = file.standardizedFileURL
        guard depth < 8, !scan.visited.contains(file), let text = read(file) else { return }   // stops include cycles
        scan.visited.insert(file)
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if let m = line.firstMatch(of: #/^\s*\\(part|chapter|section|subsection|subsubsection)\*?\{([^}]*)\}/#) {
                scan.sections.append(OutlineItem(title: String(m.2), level: levels[String(m.1)] ?? 0, line: i + 1, file: file))
            }
            if let m = line.firstMatch(of: #/%\s*TODO:?\s*(.+)$/#) {
                scan.todos.append(OutlineItem(title: String(m.1), level: 0, line: i + 1, file: file))
            } else if let m = line.firstMatch(of: #/\\todo(?:\[[^\]]*\])?\{([^}]*)\}/#) {
                scan.todos.append(OutlineItem(title: String(m.1), level: 0, line: i + 1, file: file))
            }
            for m in line.matches(of: #/\\label\{([^}]+)\}/#) { scan.labels.append(String(m.1)) }
            if let m = line.firstMatch(of: #/^[^%]*\\(?:input|include|subfile)\{([^}]+)\}/#) {
                let path = String(m.1)
                var child = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                if child.pathExtension.isEmpty { child.appendPathExtension("tex") }
                Outline.scan(child, base: base, read: read, into: &scan, depth: depth + 1)
            }
        }
    }

    /// Citation keys defined in a .bib file.
    static func citeKeys(in bib: String) -> [String] {
        bib.matches(of: #/@\w+\s*\{\s*([^,\s{}]+)\s*,/#).map { String($0.1) }
    }
}

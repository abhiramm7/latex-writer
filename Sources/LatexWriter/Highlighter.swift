import AppKit

/// Regex colouring applied as temporary attributes, so it never touches the text or the undo stack.
enum Highlighter {
    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    }

    private static let arg = re(#"\\(?:begin|end|usepackage|RequirePackage|documentclass|label|\w*ref|cite\w*|input|include|subfile|includegraphics|bibliography|bibliographystyle|setmainfont)(?:\[[^\]\n]*\])?\{([^}\n]*)\}"#)
    private static let command = re(#"\\(?:[a-zA-Z@]+|.)"#)
    private static let math = re(#"(?<!\\)\$[^$\n]+\$"#)
    private static let comment = re(#"(?<!\\)%.*"#)
    private static let bibEntry = re(#"@\w+"#)
    private static let bibKey = re(#"@\w+\s*\{\s*([^,\s]+)"#)
    private static let bibField = re(#"^\s*([A-Za-z]+)\s*="#)

    private typealias Rule = (NSRegularExpression, Int, NSColor)   // regex, capture group, colour

    // shortcut: recolours the whole file on every change and only knows single-line constructs,
    // so display-math environments stay uncoloured; switch to an incremental parser if files get large
    static func apply(to lm: NSLayoutManager, text: String, theme: Theme, errorLines: Set<Int>, bib: Bool = false) {
        let s = text as NSString
        let full = NSRange(location: 0, length: s.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        // later rules win: math over commands, comments over everything
        let rules: [Rule] = bib
            ? [(bibField, 1, theme.arg), (bibEntry, 0, theme.cmd), (bibKey, 1, theme.math), (comment, 0, theme.comment)]
            : [(command, 0, theme.cmd), (arg, 1, theme.arg), (math, 0, theme.math), (comment, 0, theme.comment)]
        for (regex, group, color) in rules {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let r = match?.range(at: group), r.location != NSNotFound else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r)
            }
        }
        for line in errorLines {
            guard let r = range(ofLine: line, in: s) else { continue }
            lm.addTemporaryAttribute(.backgroundColor, value: theme.errBg, forCharacterRange: r)
        }
    }

    /// True when a range touches a command, a command argument or inline math. Spelling and grammar skip those.
    static func isCode(_ range: NSRange, in s: NSString) -> Bool {
        guard NSMaxRange(range) <= s.length else { return false }
        let line = s.lineRange(for: range)
        if s.substring(with: line).hasPrefix("% !TEX") { return true }   // magic comments are settings, not prose
        for (regex, group) in [(arg, 1), (command, 0), (math, 0)] {
            var hit = false
            regex.enumerateMatches(in: s as String, range: line) { match, _, stop in
                guard let r = match?.range(at: group), r.location != NSNotFound else { return }
                if NSIntersectionRange(r, range).length > 0 { hit = true; stop.pointee = true }
            }
            if hit { return true }
        }
        return false
    }

    /// Character range of a 1-based line, or nil when the text has fewer lines.
    static func range(ofLine line: Int, in s: NSString) -> NSRange? {
        var r = NSRange(location: 0, length: 0)
        for _ in 1...max(line, 1) {
            guard NSMaxRange(r) < s.length else { return nil }
            r = s.lineRange(for: NSRange(location: NSMaxRange(r), length: 0))
        }
        return r
    }
}

/// Line edits behind the Comment and Indent commands. Pure, so they can be tested without a text view.
enum Lines {
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    /// Uncomments when every non-blank line is already commented, otherwise comments them all.
    static func toggleComment(_ lines: [String]) -> [String] {
        let content = lines.filter { !isBlank($0) }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.drop(while: \.isWhitespace).hasPrefix("%") }
        return lines.map { line in
            if isBlank(line) { return line }
            return allCommented ? line.replacing(#/^(\s*)% ?/#) { String($0.1) } : "% " + line
        }
    }

    static func indent(_ lines: [String]) -> [String] { lines.map { isBlank($0) ? $0 : "  " + $0 } }

    static func unindent(_ lines: [String]) -> [String] {
        lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0.hasPrefix(" ") || $0.hasPrefix("\t") ? String($0.dropFirst()) : $0 }
    }
}

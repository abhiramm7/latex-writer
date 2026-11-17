import Foundation

/// Starting points for new projects: one built in, plus any .tex file saved in the templates folder.
enum Templates {
    static let selectionKey = "templateName"
    static let builtIn = "Article (Palatino, Tufte-like)"

    /// ~/Library/Application Support/LaTeX Writer/Templates
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaTeX Writer/Templates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var names: [String] {
        let saved = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return [builtIn] + saved.filter { $0.pathExtension.lowercased() == "tex" }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// Falls back to the built-in template when a saved one has been deleted.
    static func text(_ name: String) -> String {
        if name == builtIn { return standard }
        return (try? String(contentsOf: folder.appendingPathComponent(name + ".tex"), encoding: .utf8)) ?? standard
    }

    // Palatino body, Tufte-like headings and ragged-right text, full width (no margin column)
    static let standard = #"""
    % !TEX program = xelatex
    \documentclass[11pt]{article}
    \usepackage[margin=1.2in]{geometry}
    \usepackage{amsmath, amssymb, graphicx, ragged2e, titlesec, fontspec}
    \setmainfont{Palatino}
    \titleformat{\section}{\Large\itshape}{}{0pt}{}
    \titleformat{\subsection}{\large\itshape}{}{0pt}{}
    \RaggedRight \setlength{\parindent}{1em}

    \title{Title}
    \author{Author}

    \begin{document}
    \maketitle

    \section{Introduction}

    \end{document}

    """#
}

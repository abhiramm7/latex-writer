import Foundation

/// What the completion popup offers, decided by what sits just before the cursor.
enum Completions {
    /// `before` is the text on the line up to the partial word; `partial` is the word being typed
    /// (it starts with a backslash when a command is being typed).
    static func candidates(before: String, partial: String, labels: [String], citeKeys: [String]) -> [String] {
        let pool: [String]
        if before.firstMatch(of: #/\\(?:eq|auto|c|C|page|name)?ref\{$/#) != nil {
            pool = labels
        } else if before.firstMatch(of: #/\\[a-zA-Z]*cite[a-zA-Z]*(?:\[[^\]]*\])*\{(?:[^}]*,\s*)?$/#) != nil {
            pool = citeKeys
        } else if before.firstMatch(of: #/\\(?:begin|end)\{$/#) != nil {
            pool = environments
        } else if partial.hasPrefix("\\") {
            pool = commands
        } else {
            return []
        }
        let needle = partial.lowercased()
        return Array(Set(pool)).filter { $0.lowercased().hasPrefix(needle) }.sorted()
    }

    static let environments = """
    abstract align align* array bmatrix cases center description document enumerate equation equation* figure \
    flushleft flushright frame gather itemize matrix minipage multline pmatrix proof quote tabular table \
    theorem lemma definition verbatim
    """.split(separator: " ").map(String.init)

    static let commands = """
    alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi rho sigma tau \
    upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Phi Psi Omega \
    frac sqrt sum prod int oint lim infty partial nabla cdot cdots ldots times div pm mp leq geq neq approx equiv \
    sim propto in notin subset subseteq cup cap forall exists to rightarrow leftarrow Rightarrow Leftrightarrow \
    mapsto left right big Big mathbb mathbf mathcal mathrm mathit operatorname overline underline hat bar tilde vec \
    sin cos tan log ln exp min max sup inf det dim text quad qquad \
    documentclass usepackage begin end title author date maketitle tableofcontents part chapter section subsection \
    subsubsection paragraph label ref eqref pageref cite citep citet bibliography bibliographystyle footnote \
    textbf textit texttt emph underline item includegraphics caption centering input include newcommand \
    renewcommand newenvironment hline toprule midrule bottomrule multicolumn vspace hspace newline newpage \
    clearpage noindent linewidth textwidth frametitle pause
    """.split(separator: " ").map { "\\" + $0 }
}

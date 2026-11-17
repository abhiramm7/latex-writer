import XCTest
@testable import LatexWriter

final class LatexWriterTests: XCTestCase {
    func testMagicCommentPicksEngine() {
        XCTAssertEqual(Engine.magic(in: "% !TEX program = lualatex\n\\documentclass{article}"), .lualatex)
        XCTAssertEqual(Engine.magic(in: "%!TEX TS-program = XeLaTeX\n"), .xelatex)
        XCTAssertNil(Engine.magic(in: "\\documentclass{article}\n% just a comment"))
    }

    private func tempProject(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("latexwriter-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }

    /// Autosave must not overwrite a file another program changed; the Save command may.
    func testAutosaveDoesNotOverwriteOutsideChanges() throws {
        let dir = try tempProject(["a.tex": "original"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.tex")
        let doc = Document()
        doc.open(file)
        doc.text = "mine"
        try "theirs".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertFalse(doc.save())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "theirs")
        XCTAssertNotNil(doc.saveError)
        XCTAssertTrue(doc.save(force: true))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine")
    }

    /// When the current file cannot be written, switching files must keep the unsaved text on screen.
    func testFailedSaveKeepsTheText() throws {
        let dir = try tempProject(["a.tex": "a", "b.tex": "b"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let doc = Document()
        doc.open(dir.appendingPathComponent("a.tex"))
        doc.text = "unsaved edit"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        doc.open(dir.appendingPathComponent("b.tex"))
        XCTAssertEqual(doc.url?.lastPathComponent, "a.tex")
        XCTAssertEqual(doc.text, "unsaved edit")
        XCTAssertNotNil(doc.saveError)
        XCTAssertFalse(doc.closeProject())
        XCTAssertEqual(doc.text, "unsaved edit")
    }

    /// The main file is the one nearest the top of the project, and is found again after files are added.
    func testMainFileChoice() throws {
        let dir = try tempProject(["thesis.tex": "\\documentclass{book}"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("old"), withIntermediateDirectories: true)
        try "\\documentclass{article}".write(to: dir.appendingPathComponent("old/chapter.tex"), atomically: true, encoding: .utf8)
        let doc = Document()
        doc.openProject(dir)
        XCTAssertEqual(doc.url?.lastPathComponent, "thesis.tex")

        try "no class here".write(to: dir.appendingPathComponent("notes.tex"), atomically: true, encoding: .utf8)
        doc.refreshFiles()
        doc.open(dir.appendingPathComponent("notes.tex"))
        XCTAssertEqual(doc.root?.lastPathComponent, "thesis.tex")
    }

    /// Deleting the file in the editor must not write it back, and the editor falls back to the main file.
    func testTrashingTheOpenFileOrItsFolder() throws {
        let dir = try tempProject(["main.tex": "\\documentclass{article}", "notes.tex": "notes"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try "chapter".write(to: dir.appendingPathComponent("chapters/a.tex"), atomically: true, encoding: .utf8)
        let delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        let doc = Document()
        doc.openProject(dir)

        doc.open(dir.appendingPathComponent("notes.tex"))
        doc.text = "edited notes"
        doc.trash(dir.appendingPathComponent("notes.tex"), remove: delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.tex").path))
        XCTAssertEqual(doc.url?.lastPathComponent, "main.tex")
        XCTAssertEqual(doc.text, "\\documentclass{article}")

        doc.open(dir.appendingPathComponent("chapters/a.tex"))
        doc.trash(dir.appendingPathComponent("chapters"), remove: delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("chapters").path))
        XCTAssertEqual(doc.url?.lastPathComponent, "main.tex")
        XCTAssertEqual(doc.files.map(\.lastPathComponent), ["main.tex"])
    }

    func testFileTreeGroupsFoldersFirst() {
        let root = URL(fileURLWithPath: "/p")
        let files = ["/p/main.tex", "/p/refs.bib", "/p/chapters/b.tex", "/p/chapters/a.tex", "/p/chapters/deep/c.tex", "/elsewhere/x.tex"]
            .map { URL(fileURLWithPath: $0) }
        let tree = FileTree.build(files, under: root)
        XCTAssertEqual(tree.map(\.name), ["chapters", "main.tex", "refs.bib"])
        XCTAssertNil(tree[0].url)
        XCTAssertEqual(tree[0].children.map(\.name), ["deep", "a.tex", "b.tex"])
        XCTAssertEqual(tree[0].children[1].url?.path, "/p/chapters/a.tex")

        let all = FileTree.visibleRows(tree, collapsed: [])
        XCTAssertEqual(all.map(\.name), ["chapters", "deep", "c.tex", "a.tex", "b.tex", "main.tex", "refs.bib"])
        XCTAssertEqual(all.map(\.depth), [0, 1, 2, 1, 1, 0, 0])
        XCTAssertEqual(FileTree.visibleRows(tree, collapsed: ["chapters"]).map(\.name), ["chapters", "main.tex", "refs.bib"])
    }

    func testMagicRootResolvesRelativeToTheFile() {
        let chapter = URL(fileURLWithPath: "/p/chapters/a.tex")
        XCTAssertEqual(Document.magicRoot(in: "% !TEX root = ../main.tex\ntext", of: chapter)?.path, "/p/main.tex")
        XCTAssertNil(Document.magicRoot(in: "text", of: chapter))
    }

    /// A chapter pulled in with \input compiles through the main file and keeps its own line numbers.
    func testErrorInIncludedFileKeepsItsLine() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/Library/TeX/texbin/latexmk"), "MacTeX not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("latexwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("main.tex"), chapter = dir.appendingPathComponent("chapters/a.tex")
        try "\\documentclass{article}\\begin{document}\n\\input{chapters/a}\n\\end{document}\n".write(to: main, atomically: true, encoding: .utf8)
        try "Fine.\n\\alpah\n".write(to: chapter, atomically: true, encoding: .utf8)

        let fromChapter = await Compiler.build(main, engine: .pdflatex, editing: chapter)
        XCTAssertEqual(fromChapter.issues.first(where: \.isError)?.line, 2)
        let fromMain = await Compiler.build(main, engine: .pdflatex)
        XCTAssertEqual(fromMain.issues.first(where: \.isError)?.file, "chapters/a.tex")
        XCTAssertNil(fromChapter.issues.first(where: \.isError)?.file)

        // source <-> PDF round trip through the real synctex tool
        let pdf = try XCTUnwrap(fromMain.pdf)
        let place = await SyncTeX.forward(line: 1, file: chapter, pdf: pdf)
        XCTAssertEqual(place?.page, 1)
        let back = await SyncTeX.inverse(try XCTUnwrap(place), pdf: pdf)
        XCTAssertEqual(back?.file.lastPathComponent, "a.tex")
        XCTAssertEqual(back?.line, 1)
    }

    func testScanFollowsInputsInReadingOrder() {
        let main = URL(fileURLWithPath: "/p/main.tex"), chapter = URL(fileURLWithPath: "/p/chapters/a.tex")
        let texts = [
            main: "\\section{One}\\label{sec:one}\n\\input{chapters/a}\n  \\subsection*{Three}\n% \\section{Hidden}\n% TODO: finish",
            chapter: "\\section{Two}\n\\todo{cite this}\n\\label{eq:x}",
        ]
        var scan = ProjectScan()
        Outline.scan(main, base: URL(fileURLWithPath: "/p"), read: { texts[$0] }, into: &scan)
        XCTAssertEqual(scan.sections.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(scan.sections.map(\.level), [0, 0, 1])
        XCTAssertEqual(scan.sections.map(\.line), [1, 1, 3])
        XCTAssertEqual(scan.sections[1].file, chapter)
        XCTAssertEqual(scan.todos.map(\.title), ["cite this", "finish"])
        XCTAssertEqual(scan.labels, ["sec:one", "eq:x"])
    }

    func testCiteKeys() {
        XCTAssertEqual(Outline.citeKeys(in: "@article{knuth1984,\n title={X}\n}\n@string{a = \"b\"}\n@book{ lamport94 ,"), ["knuth1984", "lamport94"])
    }

    func testCompletions() {
        let c = { Completions.candidates(before: $0, partial: $1, labels: ["eq:saw", "sec:intro"], citeKeys: ["knuth1984", "lamport94"]) }
        XCTAssertEqual(c("see \\eqref{", "eq"), ["eq:saw"])
        XCTAssertEqual(c("as in \\cite{", ""), ["knuth1984", "lamport94"])
        XCTAssertEqual(c("\\citep[p.~2]{knuth1984, ", "la"), ["lamport94"])
        XCTAssertEqual(c("\\begin{", "equ"), ["equation", "equation*"])
        XCTAssertEqual(c("x = ", "\\fra"), ["\\frac", "\\frametitle"])
        XCTAssertEqual(c("plain ", "word"), [])
    }

    func testCommentAndIndent() {
        XCTAssertEqual(Lines.toggleComment(["a", "", "  b"]), ["% a", "", "%   b"])
        XCTAssertEqual(Lines.toggleComment(["% a", "", "  %b"]), ["a", "", "  b"])
        XCTAssertEqual(Lines.toggleComment(["% a", "b"]), ["% % a", "% b"])
        XCTAssertEqual(Lines.unindent(Lines.indent(["a", "  b"])), ["a", "  b"])
    }

    func testSearchAndReplace() {
        let file = URL(fileURLWithPath: "/p/main.tex")
        let hits = Search.find("gibbs", in: "The Gibbs effect\nnothing\n  gibbs again", file: file)
        XCTAssertEqual(hits.map(\.line), [3])
        XCTAssertEqual(hits[0].snippet, "gibbs again")
        // case-sensitive, so a word never rewrites a command
        let (text, count) = Search.replace("Section", with: "Part", in: "\\section{Section one} Section")
        XCTAssertEqual(text, "\\section{Part one} Part")
        XCTAssertEqual(count, 2)
    }

    func testSyncTeXOutputParsing() {
        let place = SyncTeX.parseView("SyncTeX result begin\nOutput:a.pdf\nPage:2\nx:107.38\ny:383.85\nh:86.3\nPage:3\nx:1\ny:2\n")
        XCTAssertEqual(place?.page, 2)
        XCTAssertEqual(place?.y, 383.85)
        let source = SyncTeX.parseEdit("Output:a.pdf\nInput:/p/./main.tex\nLine:17\nColumn:-1\n")
        XCTAssertEqual(source?.file.path, "/p/main.tex")
        XCTAssertEqual(source?.line, 17)
        XCTAssertNil(SyncTeX.parseEdit("SyncTeX result begin\nSyncTeX result end\n"))
    }

    func testParseLog() {
        let log = """
        ./main.tex:17: Undefined control sequence.
        ./chapters/a.tex:3: Missing $ inserted.
        LaTeX Warning: Reference `eq:saw' on page 1 undefined on input line 12.
        Overfull \\hbox (4.2pt too wide) in paragraph at lines 10--11
        This is XeTeX, Version 3.14
        """
        let issues = Compiler.parseLog(log, file: "main.tex")
        XCTAssertEqual(issues.map(\.line), [17, 3, 12, 10])
        XCTAssertEqual(issues.map(\.file), [nil, "chapters/a.tex", nil, nil])
        XCTAssertEqual(issues.map(\.isError), [true, true, false, false])
        XCTAssertEqual(issues[0].message, "Undefined control sequence.")
        XCTAssertEqual(issues[1].message, "Missing $ inserted.")
        XCTAssertEqual(issues[2].message, "Reference `eq:saw' on page 1 undefined")
        XCTAssertEqual(issues[3].message, "Overfull \\hbox (4.2pt too wide)")
    }

    func testRangeOfLine() {
        let s = "ab\ncd\n" as NSString
        XCTAssertEqual(Highlighter.range(ofLine: 1, in: s), NSRange(location: 0, length: 3))
        XCTAssertEqual(Highlighter.range(ofLine: 2, in: s), NSRange(location: 3, length: 3))
        XCTAssertNil(Highlighter.range(ofLine: 3, in: s))
        XCTAssertNil(Highlighter.range(ofLine: 1, in: ""))
    }

    /// End to end against the real system LaTeX: the default template builds, and an error reports its line.
    func testBuildsTemplateAndReportsErrorLine() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/Library/TeX/texbin/latexmk"), "MacTeX not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("latexwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tex = dir.appendingPathComponent("main.tex")

        try Templates.standard.write(to: tex, atomically: true, encoding: .utf8)
        let good = await Compiler.build(tex, engine: Engine.magic(in: Templates.standard)!)
        XCTAssertNotNil(good.pdf)
        XCTAssertFalse(good.issues.contains(where: \.isError), "\(good.issues.map(\.message))")

        let broken = Templates.standard.replacingOccurrences(of: "\\section{Introduction}\n", with: "\\section{Introduction}\n\\alpah\n")
        try broken.write(to: tex, atomically: true, encoding: .utf8)
        let bad = await Compiler.build(tex, engine: .xelatex)
        let line = broken.components(separatedBy: "\n").firstIndex(of: "\\alpah")! + 1
        XCTAssertEqual(bad.issues.first(where: \.isError)?.line, line)
        try FileManager.default.removeItem(at: bad.pdf!)
        let stillBad = await Compiler.build(tex, engine: .xelatex)
        XCTAssertNotNil(stillBad.pdf, "a document with errors still gets a preview")

        // switching engine must not trip over the other engine's files
        try "\\documentclass{article}\\begin{document}Hi\\end{document}\n".write(to: tex, atomically: true, encoding: .utf8)
        let pdflatex = await Compiler.build(tex, engine: .pdflatex)
        XCTAssertNotNil(pdflatex.pdf)
        XCTAssertFalse(pdflatex.issues.contains(where: \.isError))
    }
}

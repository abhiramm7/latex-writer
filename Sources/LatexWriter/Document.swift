import AppKit
import Combine
import UniformTypeIdentifiers

/// One window's state: the project folder, the file being edited, autosave, and build results.
/// The edited file always exists on disk, so autosave can never lose text.
final class Document: ObservableObject {
    @Published var project: URL?       // a project is just a folder
    @Published var files: [URL] = []
    @Published var url: URL?           // the file in the editor
    @Published var text = ""
    @Published var live = true
    @Published var engine = Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .xelatex {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    @Published var issues: [Issue] = []
    @Published var outline: [OutlineItem] = []
    @Published var todos: [OutlineItem] = []
    @Published var searchHits: [SearchHit] = []
    @Published var pdfTarget: SyncTeX.Place?   // where "Show in PDF" wants the preview to scroll
    var labels: [String] = []                  // \label names, for \ref completion
    var citeKeys: [String] = []                // keys from the project's .bib files, for \cite completion
    var cursorLine = 1                         // kept current by the editor
    @Published var words = 0
    @Published var pdf: URL?
    @Published var pdfVersion = 0
    @Published var building = false
    @Published var jump: Int?          // line the editor should scroll to
    @Published var saveError: String?

    weak var window: NSWindow?         // set by the window's view, so menu commands can find the front document
    private static let all = NSHashTable<Document>.weakObjects()

    /// The document of the key window, else the main window, else any window still on screen.
    static var current: Document? {
        let open = all.allObjects.filter { $0.window?.isVisible == true }
        return open.first { $0.window?.isKeyWindow == true } ?? open.first { $0.window?.isMainWindow == true } ?? open.first
    }

    private var saved = ""
    private var diskDate: Date?        // the file's modification date when we last read or wrote it
    private var pending = false
    private var mainFile: URL?         // what chapter files without their own \documentclass compile through
    private var rootEngine: Engine?    // engine named by the main file's magic comment, when editing another file
    private var bag = Set<AnyCancellable>()
    private static var openedLaunchPath = false
    /// A menu command waiting for a window to run in, set when it was chosen with no window open.
    static var onNextWindow: ((Document) -> Void)?
    private static let texType = UTType(filenameExtension: "tex") ?? .plainText

    init() {
        Self.all.add(self)
        $text.dropFirst().debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.textSettled() }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.save() }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reloadIfChangedOnDisk() }.store(in: &bag)
        // `LatexWriter <folder or file.tex>` opens it in the first window
        if !Self.openedLaunchPath, CommandLine.arguments.count > 1, NSClassFromString("XCTestCase") == nil,
           FileManager.default.fileExists(atPath: CommandLine.arguments[1]) {
            Self.openedLaunchPath = true
            openAny(URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        if let action = Self.onNextWindow {
            Self.onNextWindow = nil
            DispatchQueue.main.async { action(self) }   // after the window is on screen
        }
    }

    // MARK: Engine and root file

    var engineLocked: Bool { Engine.magic(in: text) != nil || rootEngine != nil }
    var effectiveEngine: Engine { Engine.magic(in: text) ?? rootEngine ?? engine }
    var errorLines: Set<Int> { Set(issues.filter { $0.isError && $0.file == nil }.compactMap(\.line)) }
    var errorCount: Int { issues.filter(\.isError).count }

    /// The file latexmk runs on: a `% !TEX root` line wins, then this file if it is a whole document,
    /// then the project's main file.
    var root: URL? {
        guard let url else { return nil }
        if let magic = Self.magicRoot(in: text, of: url) { return magic }
        let isTex = url.pathExtension.lowercased() == "tex"
        if isTex, text.contains("\\documentclass") { return url }
        return mainFile ?? (isTex ? url : nil)
    }

    static func magicRoot(in text: String, of file: URL) -> URL? {
        for line in text.split(separator: "\n", maxSplits: 10, omittingEmptySubsequences: false).prefix(10) {
            guard let m = line.firstMatch(of: #/^%\s*!TEX\s+root\s*=\s*(.+?)\s*$/#.ignoresCase()) else { continue }
            return URL(fileURLWithPath: String(m.1), relativeTo: file.deletingLastPathComponent())
                .absoluteURL.standardizedFileURL
        }
        return nil
    }

    // MARK: Projects

    // Kept in UserDefaults on purpose: the system recent-documents list (NSDocumentController) was tried
    // and came back empty after the app was rebuilt, which happens constantly while this is in development.
    static var recents: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [Self.texType]
        panel.message = "Choose a project folder or a .tex file"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        openAny(u)
    }

    /// A folder opens as a project; a file opens with its folder as the project.
    func openAny(_ u: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDirectory) else {
            saveError = "\(u.lastPathComponent) no longer exists."
            return
        }
        if isDirectory.boolValue { openProject(u) } else { openProject(u.deletingLastPathComponent(), file: u) }
    }

    func openProject(_ directory: URL, file: URL? = nil) {
        guard closeProject() else { return }
        let dir = directory.standardizedFileURL
        project = dir
        var paths = (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).filter { $0 != dir.path }
        paths.insert(dir.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: "recentProjects")

        refreshFiles()
        if let target = file ?? mainFile { open(target) }
    }

    @discardableResult
    func closeProject() -> Bool {
        guard save() else { return false }   // keep the text on screen when it could not be written
        defer { saveError = nil }
        project = nil
        files = []
        mainFile = nil
        rootEngine = nil
        url = nil
        text = ""
        saved = ""
        issues = []
        outline = []
        todos = []
        searchHits = []
        labels = []
        citeKeys = []
        words = 0
        pdf = nil
        pdfVersion += 1
        return true
    }

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "Untitled Project"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let main = dir.appendingPathComponent("main.tex")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: main.path) {   // never overwrite an existing main.tex
                let template = UserDefaults.standard.string(forKey: Templates.selectionKey) ?? Templates.builtIn
                try Templates.text(template).write(to: main, atomically: true, encoding: .utf8)
            }
        } catch {
            saveError = "Could not create the project: \(error.localizedDescription)"
            return
        }
        openProject(dir)
    }

    func newFile() {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.title = "New File"
        panel.directoryURL = project
        panel.allowedContentTypes = [Self.texType]
        panel.nameFieldStringValue = "untitled.tex"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do { try "".write(to: u, atomically: true, encoding: .utf8) } catch {
            saveError = "Could not create the file: \(error.localizedDescription)"
            return
        }
        refreshFiles()
        open(u)
    }

    func saveAsTemplate() {
        let panel = NSSavePanel()
        panel.title = "Save as Template"
        panel.message = "Templates saved in this folder are offered when you create a project."
        panel.directoryURL = Templates.folder
        panel.allowedContentTypes = [Self.texType]
        panel.nameFieldStringValue = "My Template.tex"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do { try text.write(to: u, atomically: true, encoding: .utf8) } catch {
            saveError = "Could not save the template: \(error.localizedDescription)"
        }
    }

    func refreshFiles() {
        guard let project else { files = []; return }
        let wanted: Set = ["tex", "bib", "sty", "cls"]
        var found: [URL] = []
        var visited = 0
        // shortcut: three levels deep and 5000 entries at most, so a file opened from a huge folder stays instant
        let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = walker?.nextObject() as? URL, visited < 5000 {
            visited += 1
            if (walker?.level ?? 0) > 3 { walker?.skipDescendants(); continue }
            if wanted.contains(u.pathExtension.lowercased()) { found.append(u.standardizedFileURL) }
        }
        files = found.sorted { $0.path < $1.path }
        // main file: main.tex, else the first file with \documentclass, nearest the project's top level first
        let tex = files.filter { $0.pathExtension.lowercased() == "tex" }
            .sorted { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
        mainFile = tex.first { $0.lastPathComponent == "main.tex" }
            ?? tex.prefix(50).first { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("\\documentclass") }
            ?? tex.first
        citeKeys = files.filter { $0.pathExtension.lowercased() == "bib" }
            .flatMap { Outline.citeKeys(in: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    }

    // MARK: Files

    /// Moves a project file or folder to the Trash, where it can be recovered from Finder.
    /// `remove` exists so tests can delete without filling the real Trash.
    func trash(_ item: URL, remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        let item = item.standardizedFileURL
        let holdsEditorFile = url.map { $0.path == item.path || $0.path.hasPrefix(item.path + "/") } ?? false
        save()   // so the copy in the Trash has the latest text
        do { try remove(item) } catch {
            saveError = "Could not move \(item.lastPathComponent) to the Trash: \(error.localizedDescription)"
            return
        }
        if holdsEditorFile {   // the editor's file is gone: drop it without writing it back to disk
            url = nil
            text = ""
            saved = ""
            diskDate = nil
            issues = []
        }
        refreshFiles()
        if holdsEditorFile {
            if let mainFile { open(mainFile) } else { pdf = nil; pdfVersion += 1; refreshOutline() }
        } else {
            refreshOutline()
            if live { typeset() }
        }
    }

    func open(_ file: URL) {
        let u = file.standardizedFileURL
        // refuse non-UTF-8 files rather than re-encode them on the first autosave
        guard let t = try? String(contentsOf: u, encoding: .utf8) else {
            saveError = "\(u.lastPathComponent) could not be read as UTF-8 text."
            return
        }
        guard save() else { return }   // never replace text that could not be written
        let oldRoot = root
        url = u
        text = t
        saved = t
        diskDate = Self.modified(u)
        issues = []
        saveError = nil
        if root != oldRoot { pdf = nil; pdfVersion += 1 }   // same document: keep the preview and its scroll position
        refreshOutline()
        typeset()
    }

    /// Text of a project file: the editor's copy for the file being edited, the disk for the rest.
    private func currentText(of file: URL) -> String? {
        file.standardizedFileURL == url ? text : try? String(contentsOf: file, encoding: .utf8)
    }

    private func refreshOutline() {
        words = text.split(whereSeparator: \.isWhitespace).count
        var scan = ProjectScan()
        if let root {
            Outline.scan(root, base: root.deletingLastPathComponent(), read: currentText, into: &scan)
        }
        if let url, !scan.visited.contains(url) {   // a file outside the root's include tree still gets its own outline
            Outline.scan(url, base: url.deletingLastPathComponent(), read: currentText, into: &scan)
        }
        outline = scan.sections
        todos = scan.todos
        labels = scan.labels
    }

    // MARK: Navigation

    /// Opens `file` if it is not the one in the editor, then scrolls to `line`.
    func go(to line: Int?, in file: URL?) {
        if let file, file.standardizedFileURL != url { open(file) }
        jump = line
    }

    func go(to issue: Issue) {
        go(to: issue.line, in: issue.file.flatMap { name in root?.deletingLastPathComponent().appendingPathComponent(name) })
    }

    /// Scrolls the preview to the line the cursor is on.
    func showInPDF() {
        guard let url, let pdf else { return }
        let line = cursorLine
        Task { @MainActor in pdfTarget = await SyncTeX.forward(line: line, file: url, pdf: pdf) }
    }

    /// A Command-click in the preview jumps to the source line that produced that spot.
    func showSource(for place: SyncTeX.Place) {
        guard let pdf else { return }
        Task { @MainActor in
            // stale sync data can point at another copy of the project; never open files outside this one
            guard let hit = await SyncTeX.inverse(place, pdf: pdf), let project,
                  hit.file.path.hasPrefix(project.path + "/") else { return }
            go(to: hit.line, in: hit.file)
        }
    }

    // MARK: Project-wide search

    private var searchable: [URL] { files.filter { ["tex", "bib"].contains($0.pathExtension.lowercased()) } }

    func search(_ query: String) {
        searchHits = Array(searchable.flatMap { Search.find(query, in: currentText(of: $0) ?? "", file: $0) }.prefix(500))
    }

    /// Replaces every match in the project's .tex and .bib files. Returns how many were replaced.
    @discardableResult
    func replaceAll(_ query: String, with replacement: String) -> Int {
        guard save() else { return 0 }
        var total = 0
        for file in searchable {
            guard let old = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let (new, count) = Search.replace(query, with: replacement, in: old)
            guard count > 0 else { continue }
            do {
                try new.write(to: file, atomically: true, encoding: .utf8)
                total += count
            } catch {
                saveError = "Could not write \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let url { open(url) }   // reload the editor from disk
        search(query)
        return total
    }

    private func textSettled() {
        refreshOutline()
        guard url != nil, text != saved else { return }
        save()
        if live { typeset() }
    }

    private static func modified(_ file: URL) -> Date? {
        // not URL.resourceValues: a URL caches those, so a change made by another program would go unseen
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Returns false when the text could not be written. `force` (the Save command) overwrites a file
    /// that changed on disk; autosave never does.
    @discardableResult
    func save(force: Bool = false) -> Bool {
        guard let url, text != saved else { return true }
        if !force, let known = diskDate, let onDisk = Self.modified(url), onDisk != known {
            saveError = "\(url.lastPathComponent) changed on disk. Save (⌘S) to overwrite it, or reopen the project to load it."
            return false
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saved = text
            diskDate = Self.modified(url)
            saveError = nil
            if url.pathExtension.lowercased() == "bib" { refreshFiles() }   // picks up new citation keys
            return true
        } catch {
            saveError = "Not saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Picks up edits made by another program, as long as nothing here is unsaved.
    private func reloadIfChangedOnDisk() {
        guard let url, text == saved, let known = diskDate, let onDisk = Self.modified(url), onDisk != known,
              let fresh = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = fresh
        saved = fresh
        diskDate = onDisk
        refreshOutline()
        if live { typeset() }
    }

    func typeset() {
        save()
        guard let root, let editing = url else { return }
        if building { pending = true; return }   // killing latexmk mid-run can corrupt aux files, so queue one rerun
        building = true
        rootEngine = root == editing ? nil : Engine.magic(in: (try? String(contentsOf: root, encoding: .utf8)) ?? "")
        let engine = effectiveEngine
        Task { @MainActor in
            let result = await Compiler.build(root, engine: engine, editing: editing)
            building = false
            if editing == url {   // ignore results for a file that was switched away from meanwhile
                issues = result.issues
                pdf = result.pdf
                pdfVersion += 1
            }
            if pending { pending = false; typeset() }
        }
    }
}

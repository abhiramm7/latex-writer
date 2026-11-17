import Foundation

enum Engine: String, CaseIterable, Identifiable {
    case pdflatex = "pdfLaTeX", xelatex = "XeLaTeX", lualatex = "LuaLaTeX"

    var id: String { rawValue }
    var flag: String {
        switch self {
        case .pdflatex: "-pdf"
        case .xelatex: "-xelatex"
        case .lualatex: "-lualatex"
        }
    }

    /// `% !TEX program = xelatex` near the top of a file overrides the toolbar choice.
    static func magic(in text: String) -> Engine? {
        for line in text.split(separator: "\n", maxSplits: 10, omittingEmptySubsequences: false).prefix(10) {
            guard let m = line.firstMatch(of: #/^%\s*!TEX\s+(?:TS-)?program\s*=\s*(\w+)/#.ignoresCase()) else { continue }
            return allCases.first { $0.rawValue.lowercased() == m.1.lowercased() }
        }
        return nil
    }
}

struct Issue: Identifiable {
    let id = UUID()
    var line: Int?
    var message: String
    var isError: Bool
    var file: String?   // path relative to the root's folder; nil means the file in the editor
}

struct BuildResult {
    var pdf: URL?
    var issues: [Issue]
}

/// Which TeX installation to use. The default follows the system-wide MacTeX choice.
enum Distribution {
    static let key = "texbin"
    static let systemDefault = "/Library/TeX/texbin"

    static var current: String { UserDefaults.standard.string(forKey: key) ?? systemDefault }

    /// The system default plus every TeX Live year found on disk.
    static var available: [String] {
        let root = URL(fileURLWithPath: "/usr/local/texlive")
        let years = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let bins = years.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0.appendingPathComponent("bin"), includingPropertiesForKeys: nil)) ?? [] }
        return [systemDefault] + bins.map(\.path).sorted()
    }
}

enum Compiler {
    /// Runs a TeX command-line tool and returns its exit status and standard output. 127 means it could not start.
    static func run(_ args: [String], in dir: URL) async -> (status: Int32, output: String) {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.currentDirectoryURL = dir
                var env = ProcessInfo.processInfo.environment
                // apps launched from Finder do not inherit the shell PATH
                env["PATH"] = "\(Distribution.current):/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                env["max_print_line"] = "10000" // keep log lines unwrapped so they can be parsed
                p.environment = env
                let pipe = Pipe()
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return c.resume(returning: (127, "")) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()   // drain before waiting, or a full pipe deadlocks
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Runs latexmk next to the file. Output goes to a hidden folder, one per engine, so switching engines
    /// never mixes auxiliary files. `editing` is the file in the editor when it differs from the root.
    static func build(_ tex: URL, engine: Engine, editing: URL? = nil) async -> BuildResult {
        let dir = tex.deletingLastPathComponent()
        let edited = editing ?? tex
        let prefix = dir.path + "/"
        let editedName = edited.path.hasPrefix(prefix) ? String(edited.path.dropFirst(prefix.count)) : edited.lastPathComponent
        let outName = ".texbuild/" + engine.rawValue.lowercased()
        let out = dir.appendingPathComponent(outName)
        let base = tex.deletingPathExtension().lastPathComponent
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // -f: still produce a PDF when the source has errors, so the preview never goes blank
        let status = await run(["latexmk", engine.flag, "-f", "-interaction=nonstopmode", "-file-line-error",
                                "-synctex=1", "-outdir=\(outName)", tex.lastPathComponent], in: dir).status

        var issues: [Issue] = []
        if status == 127 {
            issues = [Issue(line: nil, message: "latexmk was not found. Is MacTeX installed?", isError: true)]
        } else {
            let log = (try? Data(contentsOf: out.appendingPathComponent(base + ".log")))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            issues = parseLog(log, file: editedName)
            if status != 0, !issues.contains(where: \.isError) {
                issues.insert(Issue(line: nil, message: "Typesetting failed (latexmk exit \(status)).", isError: true), at: 0)
            }
        }
        let pdf = out.appendingPathComponent(base + ".pdf")
        return BuildResult(pdf: FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil, issues: issues)
    }

    static func parseLog(_ log: String, file: String) -> [Issue] {
        var issues: [Issue] = []
        for line in log.split(separator: "\n") {
            if let m = line.firstMatch(of: #/^(?:\./)?([^:]+):(\d+): (.+)$/#) {
                issues.append(Issue(line: Int(m.2), message: String(m.3), isError: true, file: m.1 == file ? nil : String(m.1)))
            } else if let m = line.firstMatch(of: #/^(?:LaTeX|Package \w+) Warning: (.+?)(?: on input line (\d+))?\.?$/#) {
                issues.append(Issue(line: m.2.flatMap { Int($0) }, message: String(m.1), isError: false))
            } else if let m = line.firstMatch(of: #/^((?:Over|Under)full \\[hv]box .+?) (?:in paragraph )?at lines (\d+)--/#) {
                issues.append(Issue(line: Int(m.2), message: String(m.1), isError: false))
            }
        }
        return issues
    }
}

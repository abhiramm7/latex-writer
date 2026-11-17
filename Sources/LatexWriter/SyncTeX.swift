import Foundation

/// Jumps between source and PDF using the `synctex` tool and the sync data every build already writes.
enum SyncTeX {
    struct Place { var page: Int; var x: Double; var y: Double }   // page is 1-based; y is measured from the top

    /// Source line -> place in the PDF.
    static func forward(line: Int, file: URL, pdf: URL) async -> Place? {
        let out = await Compiler.run(["synctex", "view", "-i", "\(line):0:\(file.path)", "-o", pdf.path],
                                     in: pdf.deletingLastPathComponent()).output
        return parseView(out)
    }

    /// Place in the PDF -> source file and line.
    static func inverse(_ place: Place, pdf: URL) async -> (file: URL, line: Int)? {
        let out = await Compiler.run(["synctex", "edit", "-o", "\(place.page):\(place.x):\(place.y):\(pdf.path)"],
                                     in: pdf.deletingLastPathComponent()).output
        return parseEdit(out)
    }

    /// The first record is the best match.
    static func parseView(_ out: String) -> Place? {
        guard let page = out.firstMatch(of: #/(?m)^Page:(\d+)$/#).flatMap({ Int($0.1) }),
              let x = out.firstMatch(of: #/(?m)^x:([\d.]+)$/#).flatMap({ Double($0.1) }),
              let y = out.firstMatch(of: #/(?m)^y:([\d.]+)$/#).flatMap({ Double($0.1) }) else { return nil }
        return Place(page: page, x: x, y: y)
    }

    static func parseEdit(_ out: String) -> (file: URL, line: Int)? {
        guard let input = out.firstMatch(of: #/(?m)^Input:(.+)$/#),
              let line = out.firstMatch(of: #/(?m)^Line:(\d+)$/#).flatMap({ Int($0.1) }) else { return nil }
        return (URL(fileURLWithPath: String(input.1)).standardizedFileURL, line)
    }
}

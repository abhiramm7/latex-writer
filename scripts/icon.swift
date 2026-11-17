// Draws the logo: "tex" in Latin Modern (LaTeX's default font) with an integral sign as the cursor.
// Usage: swift scripts/icon.swift <roman .otf> <math .otf> <dark|light> <out.png> [out.svg]
import AppKit
import CoreText

func font(_ path: String, _ size: CGFloat) -> CTFont {
    guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL), let cg = CGFont(provider) else {
        fatalError("cannot load font \(path)")
    }
    return CTFontCreateWithGraphicsFont(cg, size, nil, nil)
}

/// The glyph outlines of a string, with the origin at the start of the baseline.
func outline(_ text: String, _ font: CTFont, kern: CGFloat = 0) -> CGPath {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: kern]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count), points = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &points)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            path.addPath(glyph, transform: CGAffineTransform(translationX: points[i].x, y: points[i].y))
        }
    }
    return path
}

func svgPath(_ path: CGPath) -> String {
    var d = ""
    let p = { (pt: CGPoint) in String(format: "%.1f %.1f", pt.x, pt.y) }
    path.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(p(pts[0]))"
        case .addLineToPoint: d += "L\(p(pts[0]))"
        case .addQuadCurveToPoint: d += "Q\(p(pts[0])) \(p(pts[1]))"
        case .addCurveToPoint: d += "C\(p(pts[0])) \(p(pts[1])) \(p(pts[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

let args = CommandLine.arguments
let dark = args[3] == "dark"
let size: CGFloat = 1024
let box = CGRect(x: 100, y: 100, width: 824, height: 824)   // macOS icon shape: a rounded square inset from the canvas
let plate = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)

let texSize = box.width * 0.42
let tex = outline("tex", font(args[1], texSize), kern: -texSize * 0.02)
let cursor = outline("∫", font(args[2], box.width * 0.5))
let gap = box.width * 0.045
let tb = tex.boundingBoxOfPath, cb = cursor.boundingBoxOfPath

// Placed by visible ink: the integral is centred on the letters, and the pair is centred in the icon as one block.
let x0 = (size - (tb.width + gap + cb.width)) / 2
let mark = CGMutablePath()
mark.addPath(tex, transform: CGAffineTransform(translationX: x0 - tb.minX, y: size / 2 - tb.midY))
mark.addPath(cursor, transform: CGAffineTransform(translationX: x0 + tb.width + gap - cb.minX, y: size / 2 - cb.midY))

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.setFillColor(dark ? .black : .white)
ctx.addPath(plate)
ctx.fillPath()
ctx.setFillColor(dark ? .white : .black)
ctx.addPath(mark)
ctx.fillPath()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))

if args.count > 5 {
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size)   // SVG's y axis points down
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824">\
    <rect x="100" y="100" width="824" height="824" rx="185" fill="\(dark ? "#000" : "#fff")"/>\
    <path fill="\(dark ? "#fff" : "#000")" d="\(svgPath(mark.copy(using: &flip)!))"/></svg>
    """
    try! svg.write(toFile: args[5], atomically: true, encoding: .utf8)
}

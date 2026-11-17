import AppKit
import SwiftUI

/// The standard macOS text view with LaTeX colours and a line-number gutter.
struct EditorView: NSViewRepresentable {
    @ObservedObject var doc: Document
    var theme: Theme
    var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let tv = LatexTextView(frame: .zero)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        _ = tv.layoutManager   // opt into TextKit 1, which the gutter and temporary colours rely on
        tv.isContinuousSpellCheckingEnabled = true   // both can be switched off in Edit > Spelling and Grammar
        tv.isGrammarCheckingEnabled = true
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // smart quotes, dashes and replacements corrupt LaTeX source
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        scroll.verticalRulerView = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let c = context.coordinator
        var restyle = c.styleKey != "\(theme.name)\(fontSize)"
        if tv.string != doc.text {   // a file was opened; typing never takes this path
            tv.string = doc.text
            tv.undoManager?.removeAllActions()
            restyle = true
        }
        if restyle {
            c.styleKey = "\(theme.name)\(fontSize)"
            let font = Theme.mono(fontSize)
            let style = NSMutableParagraphStyle()
            style.headIndent = font.maximumAdvancement.width * 2   // wrapped lines hang under the first
            tv.font = font
            tv.textColor = theme.text
            tv.backgroundColor = theme.bg
            tv.insertionPointColor = theme.accent
            tv.defaultParagraphStyle = style
            tv.typingAttributes = [.font: font, .foregroundColor: theme.text, .paragraphStyle: style]
            tv.textStorage?.addAttribute(.paragraphStyle, value: style,
                                         range: NSRange(location: 0, length: (tv.string as NSString).length))
            if let ruler = scroll.verticalRulerView as? LineNumberRuler {
                ruler.font = Theme.mono(fontSize * 0.84)
                ruler.color = theme.dim
                ruler.background = theme.bg
                ruler.needsDisplay = true
            }
        }
        if let lm = tv.layoutManager {
            Highlighter.apply(to: lm, text: tv.string, theme: theme, errorLines: doc.errorLines,
                              bib: doc.url?.pathExtension.lowercased() == "bib")
        }
        if let line = doc.jump {
            if let r = Highlighter.range(ofLine: line, in: tv.string as NSString) {
                tv.setSelectedRange(NSRange(location: r.location, length: 0))
                tv.scrollRangeToVisible(r)
                tv.window?.makeFirstResponder(tv)
            }
            DispatchQueue.main.async { doc.jump = nil }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let doc: Document
        var styleKey = ""
        init(_ doc: Document) { self.doc = doc }

        private var lastTyped = ""

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            lastTyped = replacementString ?? ""
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            doc.text = tv.string
            // offer completions after "\" and after the "{" of \ref, \cite, \begin; Esc or F5 asks any time
            if lastTyped == "\\" || lastTyped == "{" {
                let s = tv.string as NSString, at = tv.selectedRange().location
                let lineBreak = lastTyped == "\\" && at >= 2 && s.character(at: at - 2) == 92   // "\\" is not a command
                // asking with nothing to offer makes the system beep
                if !lineBreak, !candidates(in: tv, for: tv.rangeForUserCompletion).isEmpty {
                    DispatchQueue.main.async { tv.complete(nil) }
                }
            }
            lastTyped = ""
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let before = (tv.string as NSString).substring(to: min(tv.selectedRange().location, (tv.string as NSString).length))
            doc.cursorLine = before.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }

        private func candidates(in tv: NSTextView, for range: NSRange) -> [String] {
            let s = tv.string as NSString
            let lineStart = s.lineRange(for: NSRange(location: range.location, length: 0)).location
            let before = s.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            return Completions.candidates(before: before, partial: s.substring(with: range),
                                          labels: doc.labels, citeKeys: doc.citeKeys)
        }

        func textView(_ tv: NSTextView, completions words: [String], forPartialWordRange range: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = -1   // nothing is inserted until a row is picked, so typing on is never disturbed
            return candidates(in: tv, for: range)
        }

        /// Spelling and grammar marks are dropped on commands, their arguments and inline math.
        func textView(_ tv: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
            Highlighter.isCode(range, in: tv.string as NSString) ? 0 : value
        }
    }
}

final class LatexTextView: NSTextView {
    /// The word being completed: letters, digits and label punctuation, plus a leading backslash for commands.
    override var rangeForUserCompletion: NSRange {
        let s = string as NSString, end = selectedRange().location
        let extra = CharacterSet(charactersIn: ":_-.@*")
        var start = end
        while start > 0, let u = UnicodeScalar(s.character(at: start - 1)),
              CharacterSet.alphanumerics.contains(u) || extra.contains(u) { start -= 1 }
        if start > 0, s.character(at: start - 1) == 92 { start -= 1 }   // 92 is the backslash
        return NSRange(location: start, length: end - start)
    }

    /// Rewrites the selected lines through the normal editing path, so undo works.
    func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let s = string as NSString
        let range = s.lineRange(for: selectedRange())
        var block = s.substring(with: range)
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { block.removeLast() }
        let result = transform(block.components(separatedBy: "\n")).joined(separator: "\n") + (trailingNewline ? "\n" : "")
        guard shouldChangeText(in: range, replacementString: result) else { return }
        replaceCharacters(in: range, with: result)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (result as NSString).length))
    }

    /// The editor that currently has keyboard focus, for menu commands.
    static var focused: LatexTextView? { NSApp.keyWindow?.firstResponder as? LatexTextView }
}

final class LineNumberRuler: NSRulerView {
    var font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    var color = NSColor.secondaryLabelColor
    var background = NSColor.textBackgroundColor

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        clipsToBounds = true   // since macOS 14 a ruler otherwise paints over the text
        scrollView.contentView.postsBoundsChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        nc.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let s = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let originY = tv.textContainerOrigin.y

        func drawNumber(_ n: Int, fragment: NSRect) {
            let label = "\(n)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = convert(NSPoint(x: 0, y: fragment.minY + originY), from: tv).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attrs)
        }

        let visible = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        var index = s.length == 0 ? 0 : s.lineRange(for: NSRange(location: lm.characterIndexForGlyph(at: visible.location), length: 0)).location
        // shortcut: counts newlines from the top on every draw; cache line starts if very long files feel slow
        var line = s.substring(to: index).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let bottom = tv.visibleRect.maxY

        while index < s.length {
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
            if fragment.minY + originY > bottom { return }
            drawNumber(line, fragment: fragment)
            index = NSMaxRange(s.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
        // the empty last line (after a trailing newline, or in an empty file) has no glyphs of its own
        if lm.extraLineFragmentRect.height > 0 { drawNumber(line, fragment: lm.extraLineFragmentRect) }
    }
}

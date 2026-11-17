import PDFKit
import SwiftUI

/// Lets toolbar buttons reach the PDF view for page turns.
final class PDFHandle {
    weak var view: PDFView?
}

/// A PDF view that reports Command-clicks, for jumping back to the source.
final class SyncPDFView: PDFView {
    var onCommandClick: ((SyncTeX.Place) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let doc = document,
              let page = self.page(for: convert(event.locationInWindow, from: nil), nearest: true) else {
            return super.mouseDown(with: event)
        }
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        let height = page.bounds(for: .mediaBox).height   // synctex measures y from the top of the page
        onCommandClick?(SyncTeX.Place(page: doc.index(for: page) + 1, x: p.x, y: height - p.y))
    }
}

struct PDFPane: NSViewRepresentable {
    var url: URL?
    var version: Int        // bumped after every build, so the same URL reloads
    var continuous: Bool
    var background: NSColor
    var handle: PDFHandle
    var target: SyncTeX.Place?   // a place to scroll to, from "Show in PDF"
    var onPage: (String) -> Void
    var onCommandClick: (SyncTeX.Place) -> Void
    var onTargetShown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.autoScales = true
        handle.view = view
        let onPage = onPage
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view] _ in
            var label = ""
            if let view, let doc = view.document, let page = view.currentPage {
                label = "Page \(doc.index(for: page) + 1) of \(doc.pageCount)"
            }
            DispatchQueue.main.async { onPage(label) }   // never publish during a SwiftUI update
        }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        if context.coordinator.continuous != continuous {
            // only when the toggle changes, so a mode picked from the PDF's own right-click menu survives rebuilds
            context.coordinator.continuous = continuous
            view.displayMode = continuous ? .singlePageContinuous : .singlePage
        }
        view.backgroundColor = background
        view.onCommandClick = onCommandClick
        if context.coordinator.version != version {
            context.coordinator.version = version
            reload(view)
        }
        if let target, let page = view.document?.page(at: target.page - 1) {
            let height = page.bounds(for: .mediaBox).height
            // aim a little above the line so it does not sit under the top edge
            view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: height - target.y + 60)))
            DispatchQueue.main.async(execute: onTargetShown)
        }
    }

    private func reload(_ view: PDFView) {
        guard let url else { view.document = nil; return }
        // read into memory: latexmk rewrites the file while it is on screen
        guard let data = try? Data(contentsOf: url), let pdf = PDFDocument(data: data) else { return }
        // keep the reader's place across rebuilds
        let old = view.currentDestination
        let index = old?.page.flatMap { view.document?.index(for: $0) }
        view.document = pdf
        if let old, let index, let page = pdf.page(at: min(index, pdf.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: old.point))
        }
    }

    static func dismantleNSView(_ view: SyncPDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    final class Coordinator {
        var version = -1
        var continuous: Bool?
        var observer: NSObjectProtocol?
    }
}

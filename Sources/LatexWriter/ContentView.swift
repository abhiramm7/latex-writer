import SwiftUI

/// One window: sidebar | editor | PDF, with a single slim toolbar.
struct ContentView: View {
    @StateObject private var doc = Document()
    @AppStorage("theme") private var themeName = "nord"
    @AppStorage("fontSize") private var fontSize = 13.0
    @AppStorage("continuous") private var continuous = true
    @AppStorage(Templates.selectionKey) private var template = Templates.builtIn
    @State private var layout = Layout.split
    @State private var page = ""
    @State private var pdfHandle = PDFHandle()

    enum Layout { case editor, split, pdf }

    var body: some View {
        let theme = Theme.named(themeName)
        NavigationSplitView {
            Sidebar(doc: doc, theme: theme)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if doc.project == nil {
                welcome
            } else if doc.url == nil {
                VStack(spacing: 14) {
                    if let error = doc.saveError {
                        Text(error).foregroundStyle(Color(theme.err))
                    } else {
                        Text("This project has no .tex files yet.").foregroundStyle(.secondary)
                    }
                    Button("New File…") { doc.newFile() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    if layout != .pdf { editorPane(theme) }
                    if layout != .editor { pdfPane(theme) }
                }
            }
        }
        .toolbar { if doc.url != nil { toolbar(theme) } }   // the start screen stays empty
        .toolbarBackground(Color(theme.chrome), for: .windowToolbar)
        .navigationTitle(doc.project?.lastPathComponent ?? "LaTeX Writer")
        .preferredColorScheme(theme.dark.map { $0 ? .dark : .light })
        .font(.custom("IBM Plex Sans", size: 13))   // falls back to the system font when Plex is not installed
        .focusedSceneObject(doc)
        .background(WindowAccessor {
            doc.window = $0
            $0?.tabbingMode = .preferred   // each project opens as a tab of the same window
        })
        .onDisappear { doc.save() }
    }

    /// The start screen: pick a recent project, open a folder, or start one from a template.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("LaTeX Writer").font(.largeTitle)
            }
            if let error = doc.saveError { Text(error).foregroundStyle(.red) }

            let recents = Document.recents
            if !recents.isEmpty {
                Text("Recent projects").font(.headline).foregroundStyle(.secondary)
                ForEach(recents, id: \.self) { dir in
                    Button { doc.openAny(dir) } label: {
                        VStack(alignment: .leading) {
                            Text(dir.lastPathComponent)
                            Text(dir.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }
            HStack {
                Button("Open…") { doc.openPanel() }
                Spacer()
                Picker("Template", selection: $template) {
                    ForEach(Templates.names, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 290)   // a fixed width: sizing to content sometimes collapsed it to one letter
                Button("New Project…") { doc.newProject() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private func toolbar(_ theme: Theme) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                doc.live.toggle()
                if doc.live { doc.typeset() }
            } label: {
                Label(doc.live ? "LIVE" : "MANUAL", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.bold())
                    .foregroundStyle(doc.live ? Color(theme.ok) : .secondary)
            }
            .help(doc.live ? "Live typesetting is on. Click for manual." : "Live typesetting is off. Click to turn on.")

            if !doc.live {
                Button { doc.typeset() } label: { Label("Typeset", systemImage: "play.fill") }
                    .help("Typeset now (⌘B)")
            }

            Picker("Engine", selection: Binding(get: { doc.effectiveEngine }, set: { doc.engine = $0; doc.typeset() })) {
                ForEach(Engine.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(doc.engineLocked)
            .help(doc.engineLocked ? "Set by the “% !TEX program” line in this document" : "Typesetting engine")

            if doc.building {
                ProgressView().controlSize(.small)
            } else if doc.errorCount > 0 {
                Label("\(doc.errorCount) error\(doc.errorCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color(theme.err))
            } else if doc.pdf != nil {
                Image(systemName: "checkmark.circle").foregroundStyle(Color(theme.ok))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Layout", selection: $layout) {
                Image(systemName: "doc.plaintext").accessibilityLabel("Editor only").tag(Layout.editor)
                Image(systemName: "rectangle.split.2x1").accessibilityLabel("Editor and PDF").tag(Layout.split)
                Image(systemName: "doc.richtext").accessibilityLabel("PDF only").tag(Layout.pdf)
            }
            .pickerStyle(.segmented)
            .help("Editor, split, or PDF")
        }
    }

    private func editorPane(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            bar(theme) {
                Text((doc.project?.lastPathComponent ?? "") + " ›")
                Text(doc.url?.lastPathComponent ?? "").bold().foregroundStyle(Color(theme.text))
                Spacer()
                Button { doc.showInPDF() } label: { Image(systemName: "arrow.right.to.line") }
                    .accessibilityLabel("Show in PDF")
                    .help("Show this line in the PDF (⇧⌘J). ⌘-click the PDF to jump back.")
                Button("A−") { fontSize = max(9, fontSize - 1) }.help("Smaller text (⌘−)")
                Text("\(Int(fontSize))")
                Button("A+") { fontSize = min(28, fontSize + 1) }.help("Larger text (⌘+)")
            }
            EditorView(doc: doc, theme: theme, fontSize: fontSize)
            bar(theme) {
                if let error = doc.saveError { Text(error).foregroundStyle(Color(theme.err)) }
                Spacer()
                Text("\(doc.effectiveEngine.rawValue) · \(doc.building ? "typesetting…" : doc.errorCount == 1 ? "1 error" : "\(doc.errorCount) errors")")
            }
        }
        .frame(minWidth: 280)
    }

    private func pdfPane(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            bar(theme) {
                Picker("Page display", selection: $continuous) {
                    Image(systemName: "doc").accessibilityLabel("Single page").tag(false)
                    Image(systemName: "doc.on.doc").accessibilityLabel("Continuous scroll").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Single page or continuous scroll")
                Spacer()
                Text(page)
                Spacer()
                Button { pdfHandle.view?.goToPreviousPage(nil) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous page")
                Button { pdfHandle.view?.goToNextPage(nil) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next page")
            }
            PDFPane(url: doc.pdf, version: doc.pdfVersion, continuous: continuous,
                    background: theme.desk, handle: pdfHandle, target: doc.pdfTarget,
                    onPage: { page = $0 },
                    onCommandClick: { doc.showSource(for: $0) },
                    onTargetShown: { doc.pdfTarget = nil })
        }
        .frame(minWidth: 280)
    }

    /// The thin strip above and below each pane.
    private func bar<Content: View>(_ theme: Theme, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .buttonStyle(.borderless)
            .font(.custom("IBM Plex Sans", size: 11))
            .foregroundStyle(Color(theme.dim))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color(theme.chrome))
    }
}

/// Reports the NSWindow a SwiftUI view ends up in.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }   // the view has no window until after this pass
    }
}

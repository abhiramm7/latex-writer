import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // With every window closed the app stayed in the Dock, and clicking its icon opened nothing.
    // Quitting with the last window means the icon always launches straight to the start screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LatexWriterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // The per-app form of the system "Prefer tabs: Always" setting. Setting tabbingMode on a window
        // after it appears is too late: the new window has already opened on its own.
        UserDefaults.standard.set("always", forKey: "AppleWindowTabbingMode")
        // gives the bare binary (swift run) a Dock icon and menu bar; a no-op inside the .app bundle
        DispatchQueue.main.async { NSApp.setActivationPolicy(.regular) }
    }

    var body: some Scene {
        WindowGroup(id: "main") { ContentView() }
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                TextEditingCommands()   // Find, Spelling and Grammar, Substitutions; listed first so ours are added after it
                AppCommands()
            }
        Settings { SettingsView() }
    }
}

struct AppCommands: Commands {
    @FocusedObject private var doc: Document?
    @Environment(\.openWindow) private var openWindow

    /// SwiftUI only supplies `doc` while it considers a window focused, which is not dependable,
    /// so commands fall back to the document of the frontmost window.
    // Items are never disabled: their enabled state would go stale, because the fallback is not observable.
    private var target: Document? { doc ?? Document.current }

    /// Runs a project command in the front window, or in a fresh window when none is open or focused.
    private func inWindow(_ action: @escaping (Document) -> Void) {
        if let target { return action(target) }
        Document.onNextWindow = action
        openWindow(id: "main")
    }
    @AppStorage("fontSize") private var fontSize = 13.0

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { openWindow(id: "main") }.keyboardShortcut("t")
            Button("New Project…") { inWindow { $0.newProject() } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New File…") { target?.newFile() }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("Open…") { inWindow { $0.openPanel() } }.keyboardShortcut("o")
        }
        CommandGroup(after: .saveItem) {   // "after" keeps the standard Close (⌘W)
            Button("Save") { target?.save(force: true) }.keyboardShortcut("s")
            Button("Save as Template…") { target?.saveAsTemplate() }
            Button("Close Project") { target?.closeProject() }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Toggle Comment") { LatexTextView.focused?.transformSelectedLines(Lines.toggleComment) }.keyboardShortcut("/")
            Button("Indent") { LatexTextView.focused?.transformSelectedLines(Lines.indent) }.keyboardShortcut("]")
            Button("Unindent") { LatexTextView.focused?.transformSelectedLines(Lines.unindent) }.keyboardShortcut("[")
            Button("Complete") { LatexTextView.focused?.complete(nil) }   // Esc and F5 are the system shortcuts
        }
        CommandMenu("Typeset") {
            Button("Typeset") { target?.typeset() }.keyboardShortcut("b")
            Button("Show in PDF") { target?.showInPDF() }.keyboardShortcut("j", modifiers: [.command, .shift])
            Toggle("Live Typesetting", isOn: Binding(get: { target?.live ?? true }, set: { target?.live = $0; if $0 { target?.typeset() } }))
        }
        CommandGroup(after: .toolbar) {
            Button("Larger Text") { fontSize = min(28, fontSize + 1) }.keyboardShortcut("=")   // the key ⌘+ is typed on, without Shift
            Button("Smaller Text") { fontSize = max(9, fontSize - 1) }.keyboardShortcut("-")
        }
    }
}

struct SettingsView: View {
    @AppStorage("theme") private var theme = "nord"
    @AppStorage("fontSize") private var fontSize = 13.0
    @AppStorage(Distribution.key) private var texbin = Distribution.systemDefault

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                Text("Nord").tag("nord")
                Text("System").tag("system")
            }
            Stepper("Editor font size: \(Int(fontSize))", value: $fontSize, in: 9...28)
            Picker("TeX distribution", selection: $texbin) {
                ForEach(Distribution.available, id: \.self) { path in
                    Text(path == Distribution.systemDefault ? "System default" : path).tag(path)
                }
            }
            // templates are plain .tex files; edit, rename or delete them in Finder
            Button("Show Templates Folder") { NSWorkspace.shared.open(Templates.folder) }
        }
        .padding()
        .frame(width: 420)
    }
}

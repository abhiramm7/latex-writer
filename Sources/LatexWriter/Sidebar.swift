import SwiftUI

struct Sidebar: View {
    @ObservedObject var doc: Document
    var theme: Theme
    @State private var tab = Tab.outline
    @State private var query = ""
    @State private var replacement = ""
    @State private var confirmReplace = false
    @State private var collapsedFolders: Set<String> = []
    @State private var pendingTrash: FileNode?

    enum Tab { case files, outline, issues, todos, search }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                Image(systemName: "folder").help("Files").accessibilityLabel("Files").tag(Tab.files)
                Image(systemName: "list.bullet.indent").help("Outline").accessibilityLabel("Outline").tag(Tab.outline)
                Image(systemName: doc.issues.isEmpty ? "exclamationmark.triangle" : "exclamationmark.triangle.fill")
                    .help("Issues").accessibilityLabel("Issues").tag(Tab.issues)
                Image(systemName: "checklist").help("TODOs").accessibilityLabel("TODOs").tag(Tab.todos)
                Image(systemName: "magnifyingglass").help("Search the project").accessibilityLabel("Search").tag(Tab.search)
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)

            HStack { Text(title); Spacer(); Text("\(doc.words) words") }
                .font(.caption).foregroundStyle(Color(theme.dim))
                .padding(.horizontal, 12).padding(.bottom, 6)

            switch tab {
            case .files:
                // a tree like an IDE's project navigator: click a folder to fold it, click a file to open it
                List(FileTree.visibleRows(FileTree.build(doc.files, under: doc.project ?? URL(fileURLWithPath: "/")),
                                          collapsed: collapsedFolders)) { node in
                    let isFolder = node.url == nil, folded = collapsedFolders.contains(node.id)
                    row {
                        if let url = node.url { doc.open(url) } else { collapsedFolders.formSymmetricDifference([node.id]) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isFolder ? (folded ? "chevron.right" : "chevron.down") : "doc.text")
                                .font(.caption2).frame(width: 10).foregroundStyle(Color(theme.dim))
                            if isFolder { Image(systemName: "folder").foregroundStyle(Color(theme.accent)) }
                            Text(node.name).fontWeight(node.url?.path == doc.url?.path ? .bold : .regular)
                        }
                        .padding(.leading, CGFloat(node.depth) * 14)
                    }
                    .accessibilityLabel(isFolder ? "Folder \(node.name), \(folded ? "collapsed" : "expanded")" : node.name)
                    .contextMenu {
                        Button("Move to Trash", role: .destructive) { pendingTrash = node }
                    }
                }
                .confirmationDialog("Move “\(pendingTrash?.name ?? "")” to the Trash?",
                                    isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                                    presenting: pendingTrash) { node in
                    Button("Move to Trash", role: .destructive) {
                        if let project = doc.project { doc.trash(project.appendingPathComponent(node.id)) }
                    }
                } message: { node in
                    Text(node.url == nil
                         ? "The folder and everything in it go to the Trash, including files not listed here."
                         : "You can put it back from the Trash in Finder.")
                }
                .onAppear { doc.refreshFiles() }   // picks up files added outside the app
            case .outline:
                List(doc.outline) { item in
                    row { doc.go(to: item.line, in: item.file) } label: {
                        Text(item.title).padding(.leading, CGFloat(item.level) * 14)
                    }
                }
            case .issues:
                List(doc.issues) { issue in
                    row { doc.go(to: issue) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message).foregroundStyle(Color(issue.isError ? theme.err : theme.warn))
                            place(issue.file, issue.line)
                        }
                    }
                }
            case .todos:
                List(doc.todos) { item in
                    row { doc.go(to: item.line, in: item.file) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            place(item.file.map(relativePath), item.line)
                        }
                    }
                }
            case .search:
                search
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(theme.chrome))
    }

    private var title: String {
        switch tab {
        case .files: "Files"
        case .outline: "Outline"
        case .issues: "Issues (\(doc.issues.count))"
        case .todos: "TODOs (\(doc.todos.count))"
        case .search: "Search (\(doc.searchHits.count))"
        }
    }

    private var search: some View {
        VStack(spacing: 6) {
            TextField("Find in project (case-sensitive)", text: $query).onSubmit { doc.search(query) }
            HStack {
                TextField("Replace with", text: $replacement)
                Button("All") {
                    doc.search(query)   // count what is in the field now, not the last search
                    confirmReplace = !doc.searchHits.isEmpty
                }
                .disabled(query.isEmpty)
                    .help("Replace every match in the project")
            }
            List(doc.searchHits) { hit in
                row { doc.go(to: hit.line, in: hit.file) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.snippet).lineLimit(2)
                        place(relativePath(hit.file), hit.line)
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 8)
        .confirmationDialog("Replace “\(query)” with “\(replacement)” in every project file?",
                            isPresented: $confirmReplace) {
            Button("Replace All", role: .destructive) { doc.replaceAll(query, with: replacement) }
        } message: {
            Text("\(doc.searchHits.count) lines match. Files are rewritten on disk and this cannot be undone.")
        }
    }

    private func place(_ file: String?, _ line: Int?) -> some View {
        Text([file, line.map { "line \($0)" }].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(Color(theme.dim))
    }

    private func relativePath(_ file: URL) -> String {
        guard let prefix = doc.project.map({ $0.path + "/" }), file.path.hasPrefix(prefix) else { return file.lastPathComponent }
        return String(file.path.dropFirst(prefix.count))
    }

    /// A full-width clickable row.
    private func row<Label: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

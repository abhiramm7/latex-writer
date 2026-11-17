import Foundation

/// One row of the project navigator. A folder has no `url`.
struct FileNode: Identifiable {
    let id: String          // path relative to the project folder
    var name: String
    var url: URL?
    var children: [FileNode] = []
    var depth = 0
}

enum FileTree {
    /// Groups a flat file list into folders, folders first, then files, each sorted by name.
    static func build(_ files: [URL], under root: URL) -> [FileNode] {
        let prefix = root.path + "/"
        let paths = files.filter { $0.path.hasPrefix(prefix) }.map { $0.path.dropFirst(prefix.count).split(separator: "/").map(String.init) }
        return build(paths, prefix: "", root: root, depth: 0)
    }

    private static func build(_ paths: [[String]], prefix: String, root: URL, depth: Int) -> [FileNode] {
        Dictionary(grouping: paths.filter { !$0.isEmpty }, by: { $0[0] }).map { name, members in
            let id = prefix + name
            let rest = members.map { Array($0.dropFirst()) }
            if rest.contains(where: \.isEmpty) {   // a path ends here, so this is a file
                return FileNode(id: id, name: name, url: root.appendingPathComponent(id), depth: depth)
            }
            return FileNode(id: id, name: name, children: build(rest, prefix: id + "/", root: root, depth: depth + 1), depth: depth)
        }
        .sorted { ($0.url == nil ? 0 : 1, $0.name.lowercased()) < ($1.url == nil ? 0 : 1, $1.name.lowercased()) }
    }

    /// The rows to show, top to bottom, leaving out the contents of collapsed folders.
    static func visibleRows(_ nodes: [FileNode], collapsed: Set<String>) -> [FileNode] {
        nodes.flatMap { node in
            [node] + (collapsed.contains(node.id) ? [] : visibleRows(node.children, collapsed: collapsed))
        }
    }
}

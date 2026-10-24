import PruneCore
import QuickLook
import SwiftUI

struct BrowseRow: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let node: NodeID?
    let size: Int64
    let reclaimable: Int64
    let items: Int64
    let modified: Date?
    let note: String?
    let isPackage: Bool
    let isCloud: Bool
    let isSymlink: Bool
}

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.showHidden) private var showHidden = true
    @State private var files: [DirEntry] = []
    @State private var loadedFor: String = ""
    @State private var selection: Set<BrowseRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\BrowseRow.size, order: .reverse)]
    @State private var preview: URL?

    var body: some View {
        if let tree = model.tree, let node = model.browseNode {
            let rows = makeRows(tree: tree, node: node)
            let largest = Double(max(1, rows.map(\.size).max() ?? 1))
            VStack(spacing: 0) {
                header(tree: tree, node: node)
                Divider()
                table(rows: rows, largest: largest)
            }
            .navigationTitle(node == tree.root ? (tree.rootPath == "/" ? model.volume.name : AppPaths.abbreviate(tree.rootPath)) : tree.name(node))
            .task(id: "\(tree.path(node))#\(model.treeVersion)") { await loadFiles(path: tree.path(node)) }
            .quickLookPreview($preview)
        } else {
            ContentUnavailableView("No Scan", systemImage: "folder", description: Text("Scan your Mac to see folders sorted by size."))
        }
    }

    // MARK: Header

    private func header(tree: FileTree, node: NodeID) -> some View {
        let path = tree.path(node)
        let flags = tree.flags(node)
        return VStack(alignment: .leading, spacing: 12) {
            PathBar(tree: tree, node: node)
            HStack(alignment: .center, spacing: 14) {
                FileIcon(path: path, isDirectory: true, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node == tree.root && tree.rootPath == "/" ? model.volume.name : tree.name(node))
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                    Text(KnownFolders.describe(path: path) ?? statusLine(flags))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    let p = Bytes.parts(tree.size(node))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(p.number).font(.system(size: 26, weight: .light)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(p.unit).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Text("\(tree.fileCount(node).formatted()) \(tree.fileCount(node) == 1 ? "file" : "files")")
                        .font(Theme.number(11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func statusLine(_ flags: NodeFlags) -> String {
        if flags.contains(.protected) { return "Not scanned. Allow Full Disk Access to include this folder." }
        if flags.contains(.unreadable) { return "You don't have permission to see this folder's contents." }
        if flags.contains(.cloudOnly) { return "Stored in iCloud. It doesn't use space on this Mac." }
        if flags.contains(.mountPoint) { return "A separate volume. Not included in this scan." }
        if flags.contains(.excluded) { return "Excluded from scans in Settings." }
        return " "
    }

    // MARK: Table

    private func table(rows: [BrowseRow], largest: Double) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    FileIcon(path: row.path, isDirectory: row.isDirectory && !row.isPackage || row.isPackage, size: 18)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.name.hasPrefix(".") ? .secondary : .primary)
                    if row.isCloud {
                        Image(systemName: "icloud").font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("Stored in iCloud")
                    }
                    if let note = row.note {
                        Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary).help(note)
                    }
                }
            }
            .width(min: 220, ideal: 340)

            TableColumn("Size", value: \.size) { row in
                HStack(spacing: 10) {
                    Meter(fraction: Double(row.size) / largest,
                          tint: model.inTray(row.path) ? Theme.accent : Color.secondary.opacity(0.55), height: 4)
                    Text(row.size > 0 || !row.isDirectory || row.node != nil ? Bytes.format(row.size) : "—")
                        .font(Theme.number(12))
                        .foregroundStyle(model.inTray(row.path) ? Theme.accent : .primary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Files", value: \.items) { row in
                Text(row.isDirectory && row.node != nil ? row.items.formatted() : "")
                    .font(Theme.number(11.5)).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Date Modified") { (row: BrowseRow) in
                Text(row.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("") { (row: BrowseRow) in
                TrayToggle(row: row)
            }
            .width(30)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: BrowseRow.ID.self) { ids in
            contextMenu(ids: ids, rows: rows)
        } primaryAction: { ids in
            guard let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
            activate(row)
        }
        .onKeyPress(.space) {
            guard let id = selection.first else { return .ignored }
            preview = preview == nil ? URL(fileURLWithPath: id) : nil
            return .handled
        }
        .onKeyPress(.delete) {
            let chosen = rows.filter { selection.contains($0.id) }
            guard !chosen.isEmpty else { return .ignored }
            for row in chosen { add(row) }
            return .handled
        }
        .onChange(of: model.browseNode) { selection = [] }
    }

    @ViewBuilder
    private func contextMenu(ids: Set<BrowseRow.ID>, rows: [BrowseRow]) -> some View {
        let chosen = rows.filter { ids.contains($0.id) }
        if chosen.count == 1, let row = chosen.first, row.isDirectory, row.node != nil {
            Button("Open") { activate(row) }
        }
        if !chosen.isEmpty {
            let allIn = chosen.allSatisfy { model.inTray($0.path) }
            Button(allIn ? "Deselect" : "Select") {
                for row in chosen {
                    if allIn { model.removeFromTray(row.path) } else { add(row) }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(chosen.map { URL(fileURLWithPath: $0.path) })
            }
            Button("Quick Look") { preview = URL(fileURLWithPath: chosen[0].path) }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.map(\.path).joined(separator: "\n"), forType: .string)
            }
        }
    }

    private func activate(_ row: BrowseRow) {
        if row.isDirectory, let node = row.node, !model.tree!.flags(node).contains(.package) || NSEvent.modifierFlags.contains(.option) {
            model.open(node)
        } else if row.isDirectory, let node = row.node {
            model.open(node)  // packages open too; Finder can't show their sizes
        } else {
            preview = URL(fileURLWithPath: row.path)
        }
    }

    private func add(_ row: BrowseRow) {
        model.addToTray(TrayItem(path: row.path, title: row.name, bytes: row.reclaimable, isDirectory: row.isDirectory))
    }

    // MARK: Rows

    private func makeRows(tree: FileTree, node: NodeID) -> [BrowseRow] {
        _ = model.treeVersion
        let dirPath = tree.path(node)
        let prefix = dirPath == "/" ? "/" : dirPath + "/"
        var rows: [BrowseRow] = []
        var names = Set<String>()
        for c in tree.liveChildren(node) {
            let name = tree.name(c)
            if !showHidden && name.hasPrefix(".") { continue }
            let f = tree.flags(c)
            names.insert(name)
            var note: String?
            if f.contains(.protected) { note = "Not scanned. Requires Full Disk Access." }
            else if f.contains(.unreadable) { note = "You don't have permission to see its contents." }
            else if f.contains(.mountPoint) { note = "A separate volume" }
            else if f.contains(.excluded) { note = "Excluded from scans" }
            rows.append(BrowseRow(name: name, path: prefix + name, isDirectory: true, node: c, size: tree.size(c),
                                  reclaimable: tree.reclaimable(c), items: tree.fileCount(c),
                                  modified: tree.newestModification(c), note: note,
                                  isPackage: f.contains(.package), isCloud: f.contains(.cloudOnly) || (tree.size(c) == 0 && tree.cloudBytes(c) > 0),
                                  isSymlink: false))
        }
        if loadedFor == dirPath {
            for e in files where !names.contains(e.name) {
                if !showHidden && e.isHidden { continue }
                if e.kind == .directory {
                    rows.append(BrowseRow(name: e.name, path: prefix + e.name, isDirectory: true, node: nil, size: 0,
                                          reclaimable: 0, items: 0, modified: Date(timeIntervalSince1970: TimeInterval(e.modified)),
                                          note: "Added after the last scan", isPackage: false, isCloud: e.isDataless, isSymlink: false))
                } else {
                    rows.append(BrowseRow(name: e.name, path: prefix + e.name, isDirectory: false, node: nil,
                                          size: e.allocated, reclaimable: e.reclaimable, items: 0,
                                          modified: Date(timeIntervalSince1970: TimeInterval(e.modified)), note: nil,
                                          isPackage: false, isCloud: e.isDataless, isSymlink: e.kind == .symlink))
                }
            }
        }
        return rows.sorted(using: sortOrder)
    }

    private func loadFiles(path: String) async {
        let (entries, err) = await Task.detached(priority: .userInitiated) { () -> ([DirEntry], Int32) in
            var out: [DirEntry] = []
            let err = BulkLister().list(path) { out.append($0) }
            return (out, err)
        }.value
        if err != 0, let tree = model.tree, let node = tree.node(at: path) {
            // Can't read the folder now: show the large files the scan recorded instead.
            files = tree.bigFiles.filter { $0.dir == node && !$0.removed }.map { f in
                var e = DirEntry()
                e.name = f.name
                e.kind = .file
                e.logical = f.logical
                e.allocated = f.allocated
                e.modified = Int64(f.modified)
                return e
            }
        } else {
            files = entries
        }
        loadedFor = path
    }
}

private struct TrayToggle: View {
    @Environment(AppModel.self) private var model
    let row: BrowseRow
    var body: some View {
        let selected = model.inTray(row.path)
        let covered = !selected && model.trayCovering(row.path) != nil
        Button {
            if selected { model.removeFromTray(row.path) } else {
                model.addToTray(TrayItem(path: row.path, title: row.name, bytes: row.reclaimable, isDirectory: row.isDirectory))
            }
        } label: {
            Image(systemName: selected || covered ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(selected || covered ? Theme.accent : Color.secondary)
                .symbolEffect(.bounce, value: selected)
        }
        .buttonStyle(.borderless)
        .disabled(covered || RemovalGuard.refusal(for: row.path) != nil)
        .help(covered ? "Its enclosing folder is selected" : RemovalGuard.refusal(for: row.path) ?? (selected ? "Deselect" : "Select"))
    }
}

/// Breadcrumb from the scan root to the current folder.
private struct PathBar: View {
    @Environment(AppModel.self) private var model
    let tree: FileTree
    let node: NodeID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let chain = tree.ancestors(node)
                ForEach(Array(chain.enumerated()), id: \.element) { index, n in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Button {
                        model.open(n)
                    } label: {
                        HStack(spacing: 4) {
                            FileIcon(path: tree.path(n), isDirectory: true, size: 14)
                            Text(n == tree.root ? (tree.rootPath == "/" ? model.volume.name : AppPaths.abbreviate(tree.rootPath)) : tree.name(n))
                                .font(.system(size: 11.5, weight: n == node ? .semibold : .regular))
                                .foregroundStyle(n == node ? .primary : .secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

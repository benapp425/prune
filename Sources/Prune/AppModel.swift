import AppKit
import Observation
import PruneCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview, browse, history
    case category(CleanupCategory)
}

struct TrayItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let title: String
    let bytes: Int64
    let isDirectory: Bool
    var iconPath: String? = nil
    var warning: String? = nil
}

struct Toast: Identifiable {
    let id = UUID()
    let title: String
    var detail: String? = nil
    var undo: [HistoryEntry] = []
    var isError = false
}

enum Prefs {
    static let scanRoot = "scanRoot"
    static let excluded = "excluded"
    static let showHidden = "showHidden"
    static let largeMinimumMB = "largeMinimumMB"
    static let unusedMonths = "unusedMonths"
    static let staleDays = "staleDays"
    static let onboarded = "onboarded"

    static func register() {
        UserDefaults.standard.register(defaults: [
            scanRoot: "/", showHidden: true, largeMinimumMB: 250, unusedMonths: 6, staleDays: 60, onboarded: false,
        ])
    }
}

@Observable
@MainActor
final class AppModel {
    enum Phase { case empty, scanning, ready }

    // Scan
    var phase: Phase = .empty
    private(set) var tree: FileTree?
    /// Bumped whenever the tree changes, so views reading it refresh.
    var treeVersion = 0
    var scanFiles = 0
    var scanFolders = 0
    var scanBytes: Int64 = 0
    var scanPath = ""
    var scanStarted: Date?
    /// True when the scan hasn't moved for a few seconds, usually because macOS is showing a permission prompt.
    var scanStalled = false
    private var lastProgress = Date()
    private var scanner: PruneCore.Scanner?

    // Findings
    var results: [CleanupCategory: CategoryResult] = [:]
    var duplicates: CategoryResult?
    var duplicateProgress: Double?
    var analyzing = false
    var usage: [UsageSlice] = []
    private var finder: DuplicateFinder?
    private var analysisGeneration = 0

    // System
    var volume = VolumeInfo.current()
    var snapshotCount = 0
    var hasFullDiskAccess = Permissions.hasFullDiskAccess()
    var trashSize: Int64?

    // Tray
    private(set) var tray: [TrayItem] = []
    private var trayPaths: Set<String> = []
    var showTray = false
    var confirmingTrash = false
    var working = false

    // Navigation
    var selection: SidebarItem? = .overview
    var browseNode: NodeID?
    var browseBack: [NodeID] = []
    var browseForward: [NodeID] = []

    // Feedback
    var toast: Toast?
    var showOnboarding = false
    var showWhatsNew = false

    let history = AppPaths.isDemo
        ? HistoryStore(url: URL(fileURLWithPath: NSTemporaryDirectory() + "prune-demo-history.json"))
        : HistoryStore()
    var historyEntries: [HistoryEntry] = []

    /// Guards the tree while a background analysis reads it.
    private let treeLock = NSLock()
    private var ticker: Timer?

    init() {
        Prefs.register()
        if AppPaths.isDemo {
            history.clear()
            showOnboarding = false
            adopt(DemoData.tree())
            return
        }
        historyEntries = history.entries
        showOnboarding = !UserDefaults.standard.bool(forKey: Prefs.onboarded) || (!hasFullDiskAccess && ScanCache.load() == nil)
        loadCachedScan()
        refreshSystem()
        checkForNewVersion()
    }

    /// Opens What's New once after each update. A first launch shows the welcome sheet instead.
    private func checkForNewVersion() {
        let current = Changelog.currentVersion
        let seen = UserDefaults.standard.string(forKey: "lastSeenVersion")
        if seen == nil || showOnboarding {
            UserDefaults.standard.set(current, forKey: "lastSeenVersion")
        } else if seen != current {
            showWhatsNew = true
            UserDefaults.standard.set(current, forKey: "lastSeenVersion")
        }
    }

    // MARK: Scanning

    var scanRoot: String { UserDefaults.standard.string(forKey: Prefs.scanRoot) ?? "/" }

    private func loadCachedScan() {
        Task.detached(priority: .userInitiated) {
            let cached = ScanCache.load()
            await MainActor.run {
                guard let cached, self.tree == nil, self.phase != .scanning else { return }
                self.adopt(cached)
            }
        }
    }

    func startScan() {
        guard phase != .scanning, !AppPaths.isDemo else { return }
        UserDefaults.standard.set(true, forKey: Prefs.onboarded)
        showOnboarding = false
        let excluded = Set(UserDefaults.standard.stringArray(forKey: Prefs.excluded) ?? [])
        let root = URL(fileURLWithPath: scanRoot).resolvingSymlinksInPath().path
        let scanner = PruneCore.Scanner(options: .init(root: root, excluded: excluded))
        self.scanner = scanner
        finder?.cancel()
        scanFiles = 0
        scanFolders = 0
        scanBytes = 0
        scanPath = root
        scanStarted = Date()
        lastProgress = Date()
        scanStalled = false
        withAnimation(.smooth) { phase = .scanning }
        startTicker()
        Task.detached(priority: .userInitiated) {
            let tree = scanner.run()
            if let tree { try? ScanCache.save(tree) }
            await MainActor.run { self.finishScan(tree) }
        }
    }

    func stopScan() { scanner?.cancel() }

    private func finishScan(_ newTree: FileTree?) {
        scanner = nil
        stopTickerIfIdle()
        if let newTree {
            adopt(newTree)
            Haptics.tap()
        } else {
            withAnimation(.smooth) { phase = tree == nil ? .empty : .ready }
        }
    }

    private func adopt(_ newTree: FileTree) {
        tree = newTree
        treeVersion += 1
        browseBack = []
        browseForward = []
        browseNode = newTree.node(at: AppPaths.home) ?? newTree.root
        withAnimation(.smooth) { phase = .ready }
        analyze()
        refreshSystem()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTickerIfIdle() {
        if scanner == nil && finder == nil {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        if let s = scanner {
            let files = s.progress.files.load(ordering: .relaxed)
            if files != scanFiles { lastProgress = Date() }
            let stalled = Date().timeIntervalSince(lastProgress) > 3
            if stalled != scanStalled { withAnimation(.smooth) { scanStalled = stalled } }
            scanFiles = files
            scanFolders = s.progress.folders.load(ordering: .relaxed)
            scanBytes = s.progress.bytes.load(ordering: .relaxed)
            let p = s.progress.current
            if !p.isEmpty { scanPath = p }
        }
        if let f = finder { duplicateProgress = Double(f.progress.load(ordering: .relaxed)) / 1000 }
    }

    // MARK: Analysis

    var cleanupSettings: CleanupSettings {
        var s = CleanupSettings()
        let d = UserDefaults.standard
        s.largeFileMinimum = Int64(max(50, d.integer(forKey: Prefs.largeMinimumMB))) * 1_000_000
        s.unusedMonths = max(1, d.integer(forKey: Prefs.unusedMonths))
        s.staleProjectDays = max(7, d.integer(forKey: Prefs.staleDays))
        return s
    }

    func analyze(includeDuplicates: Bool = true) {
        guard let tree else { return }
        analysisGeneration += 1
        let generation = analysisGeneration
        let settings = cleanupSettings
        let lock = treeLock
        analyzing = true
        if includeDuplicates {
            finder?.cancel()
            let f = DuplicateFinder()
            finder = f
            duplicateProgress = 0
            startTicker()
        }
        let finder = includeDuplicates ? self.finder : nil
        Task.detached(priority: .userInitiated) {
            let catalog = AppCatalog()
            let (results, usage, candidates) = lock.withLock {
                (ClutterEngine(tree: tree, catalog: catalog, settings: settings).analyze(),
                 UsageBreakdown.compute(tree),
                 finder != nil ? DuplicateFinder.candidates(tree: tree) : [])
            }
            await MainActor.run {
                guard generation == self.analysisGeneration else { return }
                withAnimation(.smooth) {
                    self.results = results
                    self.usage = usage
                    self.analyzing = false
                }
            }
            guard let finder else { return }
            let dups = AppPaths.isDemo ? DemoData.duplicates(tree) : finder.run(candidates: candidates)
            await MainActor.run {
                guard self.finder === finder else { return }
                if let dups { withAnimation(.smooth) { self.duplicates = dups } }
                self.duplicateProgress = nil
                self.finder = nil
                self.stopTickerIfIdle()
            }
        }
    }

    func result(for c: CleanupCategory) -> CategoryResult? {
        c == .duplicates ? duplicates : results[c]
    }

    /// Bytes across every category's recommended items.
    var recommendedBytes: Int64 {
        CleanupCategory.allCases.reduce(0) { $0 + (result(for: $1)?.recommendedBytes ?? 0) }
    }

    var reclaimableBytes: Int64 {
        CleanupCategory.allCases.reduce(0) { $0 + (result(for: $1)?.reclaimable ?? 0) }
    }

    /// Used space the scan couldn't see (macOS calls it System Data): protected folders, other system volumes,
    /// file system overhead. Purgeable space is shown on its own.
    var unseenBytes: Int64 {
        guard let tree, tree.rootPath == "/" else { return 0 }
        return max(0, volume.used - tree.size(tree.root))
    }

    var removingSnapshots = false

    func removeSnapshots() {
        guard !removingSnapshots else { return }
        removingSnapshots = true
        let before = volume.available
        Task.detached(priority: .userInitiated) {
            let result = Result { try TimeMachine.removeLocalSnapshots() }
            await MainActor.run {
                self.removingSnapshots = false
                self.refreshSystem()
                switch result {
                case .success:
                    let gained = max(0, self.volume.available - before)
                    self.show(Toast(title: "Removed Local Snapshots",
                                    detail: gained > 0 ? "\(Bytes.format(gained)) is now free." : "macOS may take a moment to update free space."))
                case .failure(let error):
                    if (error as? TimeMachine.ThinError)?.message != "Cancelled." {
                        self.show(Toast(title: "Snapshots Weren't Removed", detail: error.localizedDescription, isError: true))
                    }
                }
            }
        }
    }

    func refreshSystem() {
        if AppPaths.isDemo {
            volume = DemoData.volume
            hasFullDiskAccess = true
            snapshotCount = 0
            return
        }
        volume = VolumeInfo.current()
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        Task.detached(priority: .utility) {
            let snapshots = TimeMachine.localSnapshotCount()
            let trash = TrashService.trashSize()
            await MainActor.run {
                self.snapshotCount = snapshots
                self.trashSize = trash
            }
        }
    }

    // MARK: Tray

    func inTray(_ path: String) -> Bool { trayPaths.contains(path) }

    /// The tray item that already covers this path (itself or a folder above it).
    func trayCovering(_ path: String) -> TrayItem? {
        var p = path
        while !p.isEmpty && p != "/" {
            if trayPaths.contains(p) { return tray.first { $0.path == p } }
            p = (p as NSString).deletingLastPathComponent
        }
        return nil
    }

    var trayBytes: Int64 { tray.reduce(0) { $0 + $1.bytes } }

    /// Duplicate groups whose every copy is selected, directly or through a selected folder.
    private func fullySelectedDuplicateGroups() -> [[CleanupItem]] {
        guard let d = duplicates else { return [] }
        let groups = Dictionary(grouping: d.items.filter { $0.group != nil }, by: { $0.group! })
        return groups.values.filter { copies in copies.count > 1 && copies.allSatisfy { trayCovering($0.path) != nil } }
    }

    /// Inserts an item, then takes it back out if that leaves some duplicated file with no copy outside the
    /// selection. Returns false when it was refused.
    private func insertKeepingOneCopy(_ entry: TrayItem) -> Bool {
        let prefix = entry.path + "/"
        let displaced = tray.filter { $0.path.hasPrefix(prefix) }
        tray.removeAll { $0.path.hasPrefix(prefix) }
        trayPaths = trayPaths.filter { !$0.hasPrefix(prefix) }
        tray.append(entry)
        trayPaths.insert(entry.path)
        if fullySelectedDuplicateGroups().isEmpty { return true }
        tray.removeAll { $0.path == entry.path }
        trayPaths.remove(entry.path)
        tray.append(contentsOf: displaced)
        trayPaths.formUnion(displaced.map(\.path))
        return false
    }

    @discardableResult
    func addToTray(_ item: TrayItem) -> Bool {
        if let reason = RemovalGuard.refusal(for: item.path) {
            NSSound.beep()
            show(Toast(title: "“\(item.title)” Can't Be Removed", detail: reason, isError: true))
            return false
        }
        guard trayCovering(item.path) == nil else { return false }
        // A folder replaces anything inside it that's already selected.
        var entry = item
        entry.warning = RemovalGuard.warning(for: item.path)
        var added = false
        withAnimation(.snappy) { added = insertKeepingOneCopy(entry) }
        guard added else {
            NSSound.beep()
            show(Toast(title: "At Least One Copy Must Remain",
                       detail: "Selecting “\(item.title)” would remove every copy of a duplicated file.", isError: true))
            return false
        }
        Haptics.tap()
        return true
    }

    func addToTray(_ items: [CleanupItem]) {
        var kept = 0
        for i in items where !inTray(i.path) {
            if RemovalGuard.refusal(for: i.path) != nil || trayCovering(i.path) != nil { continue }
            let entry = TrayItem(path: i.path, title: i.title, bytes: i.bytes, isDirectory: i.isDirectory,
                                 iconPath: i.iconPath, warning: RemovalGuard.warning(for: i.path))
            if !insertKeepingOneCopy(entry) { kept += 1 }
        }
        if kept > 0 {
            show(Toast(title: "\(kept) \(kept == 1 ? "Item" : "Items") Not Selected",
                       detail: "At least one copy of each duplicated file must remain."))
        }
        Haptics.tap()
    }

    func removeFromTray(_ path: String) {
        withAnimation(.snappy) {
            tray.removeAll { $0.path == path }
            trayPaths.remove(path)
        }
    }

    func removeFromTray(_ paths: [String]) {
        let set = Set(paths)
        withAnimation(.snappy) {
            tray.removeAll { set.contains($0.path) }
            trayPaths.subtract(set)
        }
    }

    func toggleTray(_ item: CleanupItem) {
        if inTray(item.path) { removeFromTray(item.path) } else {
            addToTray(TrayItem(path: item.path, title: item.title, bytes: item.bytes, isDirectory: item.isDirectory,
                               iconPath: item.iconPath))
        }
    }

    func clearTray() {
        withAnimation(.snappy) {
            tray.removeAll()
            trayPaths.removeAll()
        }
    }

    /// Puts every recommended item into the tray and opens it.
    func reviewRecommended() {
        let items = CleanupCategory.allCases.flatMap { result(for: $0)?.items.filter(\.recommended) ?? [] }
        addToTray(items)
        showTray = true
    }

    // MARK: Moving to the Trash

    func moveTrayToTrash() {
        guard !tray.isEmpty, !working else { return }
        if let group = fullySelectedDuplicateGroups().first {
            confirmingTrash = false
            NSSound.beep()
            show(Toast(title: "At Least One Copy Must Remain",
                       detail: "Every copy of “\(group[0].title)” is selected. Deselect one to keep it.", isError: true))
            return
        }
        let requests = tray.map { TrashRequest(path: $0.path, bytes: $0.bytes, isDirectory: $0.isDirectory) }
        working = true
        Task.detached(priority: .userInitiated) {
            let outcome = TrashService.moveToTrash(requests)
            await MainActor.run { self.finishTrash(outcome) }
        }
    }

    private func finishTrash(_ outcome: (moved: [HistoryEntry], failed: [TrashFailure])) {
        working = false
        confirmingTrash = false
        if !outcome.moved.isEmpty { Sounds.trash() }
        history.add(outcome.moved)
        historyEntries = history.entries
        treeLock.lock()
        for entry in outcome.moved { applyRemoval(entry) }
        treeLock.unlock()
        treeVersion += 1
        removeFromTray(outcome.moved.map(\.originalPath))
        let freed = outcome.moved.reduce(Int64(0)) { $0 + $1.bytes }
        if outcome.failed.isEmpty {
            show(Toast(title: "Moved \(outcome.moved.count) \(outcome.moved.count == 1 ? "Item" : "Items") to the Trash",
                       detail: "Empty the Trash to free \(Bytes.format(freed)).", undo: outcome.moved))
        } else {
            let first = outcome.failed[0]
            show(Toast(title: "\(outcome.failed.count) of \(outcome.failed.count + outcome.moved.count) Items Couldn't Be Moved",
                       detail: "\((first.path as NSString).lastPathComponent): \(first.reason)",
                       undo: outcome.moved, isError: true))
        }
        if tray.isEmpty { showTray = false }
        persistTree()
        analyze(includeDuplicates: false)
        prune(duplicatesAfterRemoving: Set(outcome.moved.map(\.originalPath)))
        refreshSystem()
    }

    private func applyRemoval(_ entry: HistoryEntry) {
        guard let tree else { return }
        if entry.isDirectory {
            // A folder the scan never saw wasn't counted, so there's nothing to take off.
            if let n = tree.node(at: entry.originalPath) { tree.markRemoved(n) }
        } else if let dir = tree.node(at: (entry.originalPath as NSString).deletingLastPathComponent) {
            let name = (entry.originalPath as NSString).lastPathComponent
            let big = tree.bigFiles.first { $0.dir == dir && $0.name == name && !$0.removed }
            tree.removeFile(in: dir, named: name, allocated: big?.allocated ?? entry.bytes,
                            privateSize: big?.privateSize ?? entry.bytes)
        }
    }

    private func applyRestore(_ entry: HistoryEntry) {
        guard let tree else { return }
        let parentPath = (entry.originalPath as NSString).deletingLastPathComponent
        guard let dir = tree.node(at: parentPath) else { return }
        let name = (entry.originalPath as NSString).lastPathComponent
        if entry.isDirectory {
            if let n = tree.children(dir).first(where: { tree.name($0) == name && tree.flags($0).contains(.removed) }) {
                tree.unmarkRemoved(n)
            }
        } else {
            let big = tree.bigFiles.first { $0.dir == dir && $0.name == name && $0.removed }
            tree.restoreFile(in: dir, named: name, allocated: big?.allocated ?? entry.bytes,
                             privateSize: big?.privateSize ?? entry.bytes)
        }
    }

    /// Drops copies that are now in the Trash, whether moved on their own or inside a folder.
    private func prune(duplicatesAfterRemoving paths: Set<String>) {
        guard let d = duplicates else { return }
        func gone(_ p: String) -> Bool {
            var cur = p
            while !cur.isEmpty && cur != "/" {
                if paths.contains(cur) { return true }
                cur = (cur as NSString).deletingLastPathComponent
            }
            return false
        }
        let removed = d.items.filter { gone($0.path) }
        guard !removed.isEmpty else { return }
        var items = d.items.filter { !gone($0.path) }
        var counts: [Int: Int] = [:]
        for i in items { counts[i.group ?? -1, default: 0] += 1 }
        items.removeAll { (counts[$0.group ?? -1] ?? 0) < 2 }
        // A group that lost copies saves what its remaining extra copies hold.
        var gains: [Int: Int64] = [:]
        for (g, copies) in Dictionary(grouping: items, by: { $0.group ?? -1 }) {
            let original = d.groupGains[g] ?? 0
            let lost = removed.filter { $0.group == g }.reduce(Int64(0)) { $0 + $1.bytes }
            gains[g] = lost == 0 ? original : max(0, copies.reduce(0) { $0 + $1.bytes } - (copies.map(\.bytes).max() ?? 0))
        }
        var updated = CategoryResult(category: .duplicates, items: items, reclaimable: gains.values.reduce(0, +))
        updated.groupGains = gains
        duplicates = updated
    }

    func restore(_ entries: [HistoryEntry]) {
        var failures: [String] = []
        var restored = 0
        treeLock.lock()
        for e in entries.reversed() {
            do {
                try TrashService.restore(e)
                history.markRestored(e.id)
                applyRestore(e)
                restored += 1
            } catch {
                failures.append("\(e.name): \(error.localizedDescription)")
            }
        }
        treeLock.unlock()
        historyEntries = history.entries
        treeVersion += 1
        if failures.isEmpty {
            show(Toast(title: "Put Back \(restored) \(restored == 1 ? "Item" : "Items")"))
        } else {
            show(Toast(title: "\(failures.count) \(failures.count == 1 ? "Item" : "Items") Couldn't Be Put Back",
                       detail: failures.first, isError: true))
        }
        persistTree()
        analyze()
        refreshSystem()
    }

    func clearHistory() {
        history.clear()
        historyEntries = []
    }

    private func persistTree() {
        guard let tree else { return }
        let lock = treeLock
        Task.detached(priority: .background) {
            lock.withLock { try? ScanCache.save(tree) }
        }
    }

    func show(_ t: Toast) {
        withAnimation(.snappy) { toast = t }
        let id = t.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(t.undo.isEmpty ? 5 : 9))
            if self.toast?.id == id { withAnimation(.smooth) { self.toast = nil } }
        }
    }

    // MARK: Browsing

    func open(_ node: NodeID) {
        guard node != browseNode else { return }
        if let current = browseNode { browseBack.append(current) }
        browseForward.removeAll()
        browseNode = node
        if selection != .browse { selection = .browse }
    }

    func goBack() {
        guard let previous = browseBack.popLast() else { return }
        if let current = browseNode { browseForward.append(current) }
        browseNode = previous
    }

    func goForward() {
        guard let next = browseForward.popLast() else { return }
        if let current = browseNode { browseBack.append(current) }
        browseNode = next
    }

    func goUp() {
        guard let tree, let current = browseNode, let parent = tree.parent(current) else { return }
        open(parent)
    }

    /// Opens Browse at the folder holding this path.
    func reveal(inBrowse path: String) {
        guard let tree else { return }
        var p = path
        while !p.isEmpty {
            if let n = tree.node(at: p) {
                open(n)
                return
            }
            p = (p as NSString).deletingLastPathComponent
        }
    }

    // MARK: Finder

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.home + "/.Trash"))
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(Permissions.settingsURL)
    }
}

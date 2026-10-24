import CoreServices
import Foundation
import UniformTypeIdentifiers

public enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case caches, downloads, developer, largeOld, duplicates, leftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caches: "Caches"
        case .downloads: "Downloads"
        case .developer: "Developer"
        case .largeOld: "Large Files"
        case .duplicates: "Duplicates"
        case .leftovers: "Uninstalled Apps"
        }
    }

    public var symbol: String {
        switch self {
        case .caches: "arrow.triangle.2.circlepath"
        case .downloads: "arrow.down.circle"
        case .developer: "hammer"
        case .largeOld: "shippingbox"
        case .duplicates: "square.on.square"
        case .leftovers: "app.dashed"
        }
    }

    public var blurb: String {
        switch self {
        case .caches: "Temporary files that apps and developer tools re-create as needed."
        case .downloads: "Installers, archives and other downloads you haven't opened recently."
        case .developer: "Project dependencies, build files and Xcode data that can be re-created."
        case .largeOld: "Large files and folders you haven't opened in a while."
        case .duplicates: "Identical copies of the same file stored in more than one place."
        case .leftovers: "Support files from apps that are no longer on this Mac."
        }
    }
}

/// How sure Prune is that an item can go.
public enum Confidence: Int, Sendable, Comparable {
    case safe, rebuilds, reinstall, review

    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe to Remove"
        case .rebuilds: "Rebuilt Automatically"
        case .reinstall: "Reinstall to Restore"
        case .review: "Review"
        }
    }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let detail: String
    /// Bytes you'd get back.
    public let bytes: Int64
    public let confidence: Confidence
    public let note: String?
    public let date: Date?
    public let dateLabel: String?
    public let isDirectory: Bool
    public let recommended: Bool
    /// A file whose Finder icon represents the item (an app bundle for app caches).
    public let iconPath: String?
    public let section: String
    public var group: Int? = nil

    public init(path: String, title: String, detail: String? = nil, bytes: Int64, confidence: Confidence,
                note: String? = nil, date: Date? = nil, dateLabel: String? = nil, isDirectory: Bool,
                recommended: Bool, iconPath: String? = nil, section: String, group: Int? = nil) {
        self.path = path
        self.title = title
        self.detail = detail ?? AppPaths.abbreviate(path)
        self.bytes = bytes
        self.confidence = confidence
        self.note = note
        self.date = date
        self.dateLabel = dateLabel
        self.isDirectory = isDirectory
        self.recommended = recommended
        self.iconPath = iconPath
        self.section = section
        self.group = group
    }
}

public struct CategoryResult: Sendable {
    public let category: CleanupCategory
    public var items: [CleanupItem]
    public var sections: [String]
    /// Bytes you could get back from the whole category. For duplicates, one copy of each file stays.
    public var reclaimable: Int64
    /// For duplicates: bytes freed by keeping one copy of each group.
    public var groupGains: [Int: Int64] = [:]
    public var recommendedBytes: Int64 {
        items.filter(\.recommended).reduce(0) { $0 + $1.bytes }
    }

    public init(category: CleanupCategory, items: [CleanupItem], sections: [String]? = nil, reclaimable: Int64? = nil) {
        self.category = category
        self.items = items
        var order: [String] = []
        for i in items where !order.contains(i.section) { order.append(i.section) }
        self.sections = sections.map { s in s.filter { order.contains($0) } } ?? order
        self.reclaimable = reclaimable ?? items.reduce(0) { $0 + $1.bytes }
    }

    public func items(in section: String) -> [CleanupItem] { items.filter { $0.section == section } }
}

public struct CleanupSettings: Sendable, Equatable {
    public var largeFileMinimum: Int64 = 250_000_000
    public var unusedMonths = 6
    public var staleProjectDays = 60
    public init() {}
}

/// Finds clutter in a scanned tree. Every rule says why its items are safe or not.
public final class ClutterEngine {
    let tree: FileTree
    let catalog: AppCatalog
    let settings: CleanupSettings
    let home = AppPaths.home
    let now = Date()
    let running = AppCatalog.running()
    private var claimed = Set<String>()

    public init(tree: FileTree, catalog: AppCatalog, settings: CleanupSettings) {
        self.tree = tree
        self.catalog = catalog
        self.settings = settings
    }

    public func analyze() -> [CleanupCategory: CategoryResult] {
        var out: [CleanupCategory: CategoryResult] = [:]
        out[.developer] = developer()   // first, so its caches aren't listed again under Caches
        out[.caches] = caches()
        out[.downloads] = downloads()
        out[.largeOld] = largeOld()
        out[.leftovers] = leftovers()
        return out
    }

    // MARK: Helpers

    private func days(_ n: Int) -> TimeInterval { TimeInterval(n) * 86_400 }

    private func folder(_ path: String, title: String, section: String, confidence: Confidence, recommended: Bool,
                        note: String? = nil, date: Date? = nil, dateLabel: String? = nil, iconPath: String? = nil,
                        detail: String? = nil, minimum: Int64 = 1_000_000) -> CleanupItem? {
        guard !claimed.contains(path), let n = tree.node(at: path) else { return nil }
        return folder(n, path: path, title: title, section: section, confidence: confidence, recommended: recommended,
                      note: note, date: date, dateLabel: dateLabel, iconPath: iconPath, detail: detail, minimum: minimum)
    }

    private func folder(_ n: NodeID, path: String, title: String, section: String, confidence: Confidence,
                        recommended: Bool, note: String? = nil, date: Date? = nil, dateLabel: String? = nil,
                        iconPath: String? = nil, detail: String? = nil, minimum: Int64 = 1_000_000) -> CleanupItem? {
        guard !claimed.contains(path), !tree.flags(n).contains(.removed) else { return nil }
        let bytes = tree.reclaimable(n)
        guard bytes >= minimum, RemovalGuard.refusal(for: path) == nil else { return nil }
        claimed.insert(path)
        return CleanupItem(path: path, title: title, detail: detail, bytes: bytes, confidence: confidence, note: note,
                           date: date, dateLabel: dateLabel, isDirectory: true, recommended: recommended,
                           iconPath: iconPath, section: section)
    }

    /// The running app that owns a folder, if any.
    private func runningApp(forFolder name: String) -> String? {
        let lower = name.lowercased()
        if let app = running.ids[lower] { return app }
        if AppCatalog.looksLikeBundleID(name) {
            return running.ids.first { lower.hasPrefix($0.key + ".") || $0.key.hasPrefix(lower + ".") }?.value
        }
        if let app = running.names[lower] { return app }
        guard lower.count >= 4 else { return nil }
        return running.names.first { $0.key.hasPrefix(lower + " ") }?.value
    }

    /// Folders where people keep their own files and projects: the home folder minus Library and hidden tool folders.
    private func userAreaRoots() -> [NodeID] {
        var roots: [NodeID] = []
        if let h = tree.node(at: home) {
            roots += tree.liveChildren(h).filter {
                let name = tree.name($0)
                return !name.hasPrefix(".") && name != "Library"
            }
        }
        if let shared = tree.node(at: "/Users/Shared") { roots.append(shared) }
        return roots
    }

    private func inUserArea(_ path: String) -> Bool {
        if path.hasPrefix("/Users/Shared/") { return !RemovalGuard.insidePackage(path) }
        guard path.hasPrefix(home + "/") else { return false }
        let rel = path.dropFirst(home.count + 1)
        if rel.hasPrefix(".") || rel.hasPrefix("Library/") { return false }
        return !RemovalGuard.insidePackage(path)
    }

    /// Finder's name for a file type: "Disk Image", "ZIP archive".
    static func kind(ofExtension ext: String) -> String? {
        UTType(filenameExtension: ext)?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Caches

    private struct Tool {
        let path: String
        let title: String
        var confidence = Confidence.rebuilds
        var recommended = true
        var note: String? = nil
    }

    func caches() -> CategoryResult {
        var items: [CleanupItem] = []
        let h = home
        let tools: [Tool] = [
            Tool(path: h + "/.npm/_cacache", title: "npm cache"),
            Tool(path: h + "/.npm/_npx", title: "npx packages"),
            Tool(path: h + "/Library/Caches/Yarn", title: "Yarn cache"),
            Tool(path: h + "/.yarn/berry/cache", title: "Yarn cache"),
            Tool(path: h + "/.bun/install/cache", title: "Bun cache"),
            Tool(path: h + "/Library/Caches/pip", title: "pip cache"),
            Tool(path: h + "/.cache/pip", title: "pip cache"),
            Tool(path: h + "/Library/Caches/Homebrew", title: "Homebrew downloads"),
            Tool(path: h + "/.cache/huggingface", title: "Hugging Face models", confidence: .review, recommended: false,
                 note: "Downloaded again when needed"),
            Tool(path: h + "/.gradle/caches", title: "Gradle cache"),
            Tool(path: h + "/.m2/repository", title: "Maven libraries", recommended: false),
            Tool(path: h + "/.cargo/registry", title: "Cargo registry"),
            Tool(path: h + "/go/pkg/mod", title: "Go modules"),
            Tool(path: h + "/Library/Caches/go-build", title: "Go build cache"),
            Tool(path: h + "/Library/Caches/CocoaPods", title: "CocoaPods cache"),
            Tool(path: h + "/Library/Caches/ms-playwright", title: "Playwright browsers", recommended: false,
                 note: "Downloaded again by playwright install"),
            Tool(path: h + "/.cache/puppeteer", title: "Puppeteer browsers", recommended: false),
            Tool(path: h + "/Library/Caches/JetBrains", title: "JetBrains caches"),
        ]
        for t in tools {
            if let i = folder(t.path, title: t.title, section: "Developer Tools", confidence: t.confidence,
                              recommended: t.recommended, note: t.note) { items.append(i) }
        }
        // ~/.cache follows the XDG rule: anything inside can be deleted.
        if let xdg = tree.node(at: h + "/.cache") {
            for c in tree.liveChildren(xdg) {
                let name = tree.name(c)
                if let i = folder(c, path: tree.path(c), title: name, section: "Developer Tools", confidence: .rebuilds,
                                  recommended: true) { items.append(i) }
            }
        }

        // ~/Library/Caches, one item per app.
        if let lib = tree.node(at: h + "/Library/Caches") {
            for c in tree.liveChildren(lib) {
                let name = tree.name(c)
                let apple = name.hasPrefix("com.apple.")
                let user = runningApp(forFolder: name)
                let open = user != nil
                let note: String? = user.map { "In use by \($0)" } ?? (apple ? "Used by macOS" : nil)
                if let i = folder(c, path: tree.path(c), title: catalog.displayName(forFolder: name), section: "App Caches",
                                  confidence: .rebuilds, recommended: !apple && !open, note: note,
                                  iconPath: catalog.iconPath(forFolder: name)) { items.append(i) }
            }
        }
        // Sandboxed apps keep caches inside their container.
        if let containers = tree.node(at: h + "/Library/Containers") {
            for c in tree.liveChildren(containers) {
                let name = tree.name(c)
                guard !name.hasPrefix("com.apple."),
                      let cache = tree.node(at: tree.path(c) + "/Data/Library/Caches") else { continue }
                let user = runningApp(forFolder: name)
                if let i = folder(cache, path: tree.path(cache), title: catalog.displayName(forFolder: name),
                                  section: "App Caches", confidence: .rebuilds, recommended: user == nil,
                                  note: user.map { "In use by \($0)" },
                                  iconPath: catalog.iconPath(forFolder: name), minimum: 5_000_000) { items.append(i) }
            }
        }
        // Apps built on Chromium and Electron keep web caches in Application Support.
        let webCaches: Set<String> = ["Cache", "Code Cache", "GPUCache", "CachedData", "ShaderCache", "DawnCache",
                                      "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "component_crx_cache",
                                      "CachedExtensionVSIXs", "Crashpad"]
        if let support = tree.node(at: h + "/Library/Application Support") {
            for app in tree.liveChildren(support) {
                let appName = tree.name(app)
                let user = runningApp(forFolder: appName)
                let open = user != nil
                var levels: [NodeID] = [app]
                levels += tree.liveChildren(app).filter { tree.childCount[Int($0)] > 0 }
                for parent in levels {
                    for c in tree.liveChildren(parent) where webCaches.contains(tree.name(c)) {
                        let label = parent == app ? appName : appName + " · " + tree.name(parent)
                        if let i = folder(c, path: tree.path(c), title: label + " · " + tree.name(c),
                                          section: "Web Caches", confidence: .rebuilds, recommended: !open,
                                          note: user.map { "In use by \($0)" },
                                          minimum: 5_000_000) { items.append(i) }
                    }
                }
            }
        }
        // ~/Library/Logs itself stays, because apps expect it to be there. Each app's logs are listed instead.
        if let logs = tree.node(at: h + "/Library/Logs") {
            for c in tree.liveChildren(logs) {
                if let i = folder(c, path: tree.path(c), title: catalog.displayName(forFolder: tree.name(c)), section: "Logs",
                                  confidence: .safe, recommended: true, note: "Diagnostic logs", minimum: 5_000_000) {
                    items.append(i)
                }
            }
        }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .caches, items: items, sections: ["App Caches", "Developer Tools", "Web Caches", "Logs"])
    }

    // MARK: Downloads

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso", "tar", "gz", "tgz", "bz2",
                                                   "xz", "7z", "rar", "msi", "exe", "apk", "ipa", "crx"]

    func downloads() -> CategoryResult {
        let dir = home + "/Downloads"
        var items: [CleanupItem] = []
        let dirNode = tree.node(at: dir)
        var entries: [DirEntry] = []
        if BulkLister().list(dir, { entries.append($0) }) != 0, let d = dirNode {
            // The folder can't be read right now: fall back to what the scan saw.
            entries = []
            for c in tree.liveChildren(d) {
                var e = DirEntry()
                e.name = tree.name(c)
                e.kind = .directory
                e.modified = Int64(tree.newestModification(c).timeIntervalSince1970)
                e.added = e.modified
                entries.append(e)
            }
            for f in tree.bigFiles where f.dir == d && !f.removed {
                var e = DirEntry()
                e.name = f.name
                e.kind = .file
                e.logical = f.logical
                e.allocated = f.allocated
                e.modified = Int64(f.modified)
                e.added = Int64(f.added)
                entries.append(e)
            }
        }
        for e in entries {
            guard !e.isHidden, !e.isDataless else { continue }
            let path = dir + "/" + e.name
            let ext = (e.name as NSString).pathExtension.lowercased()
            var bytes = e.reclaimable
            if e.kind == .directory {
                guard let d = dirNode, let n = tree.child(d, named: e.name) else { continue }
                bytes = tree.reclaimable(n)
            }
            guard bytes >= 100_000, RemovalGuard.refusal(for: path) == nil else { continue }
            let added = Date(timeIntervalSince1970: TimeInterval(e.added > 0 ? e.added : e.modified))
            let used = Self.spotlightLastUsed(path)
            let lastTouch = max(added, used ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(e.modified)))
            let age = now.timeIntervalSince(added)
            let idle = now.timeIntervalSince(lastTouch)
            if ["crdownload", "download", "part", "partial"].contains(ext) && age > days(1) {
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .safe,
                                         note: "Incomplete download", date: added, dateLabel: "Added",
                                         isDirectory: e.kind == .directory, recommended: true, section: "Incomplete Downloads"))
            } else if e.kind != .directory && Self.installerExtensions.contains(ext) && age > days(14) {
                // Installers are recommended once unused for a month. Archives may be the only copy of
                // something, so they're listed but never selected for you.
                let installer = ["dmg", "pkg", "mpkg", "xip"].contains(ext)
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes,
                                         confidence: installer ? .safe : .review, note: Self.kind(ofExtension: ext),
                                         date: used ?? added, dateLabel: used != nil ? "Last Opened" : "Added",
                                         isDirectory: false, recommended: installer && idle > days(30),
                                         section: "Installers and Archives"))
            } else if ext == "app" {
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .review,
                                         note: "Not in the Applications folder", date: lastTouch,
                                         dateLabel: "Last Opened", isDirectory: true, recommended: false,
                                         iconPath: path, section: "Apps"))
            } else if idle > days(90) {
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .review, note: nil,
                                         date: lastTouch, dateLabel: used != nil ? "Last Opened" : "Added",
                                         isDirectory: e.kind == .directory, recommended: false,
                                         section: "Not Opened in 3 Months"))
            }
        }
        for i in items { claimed.insert(i.path) }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .downloads, items: items,
                              sections: ["Installers and Archives", "Incomplete Downloads", "Apps", "Not Opened in 3 Months"])
    }

    // MARK: Developer

    /// A virtual environment folder by its usual name and layout, not just because it holds pyvenv.cfg
    /// (running `python -m venv .` turns a whole project folder into one).
    static func isVirtualEnvironment(_ n: NodeID, in tree: FileTree) -> Bool {
        let names: Set<String> = [".venv", "venv", "env", ".env", "virtualenv", ".virtualenv"]
        guard names.contains(tree.name(n)) else { return false }
        let kids = Set(tree.liveChildren(n).map { tree.name($0) })
        return kids.contains("bin") && (kids.contains("lib") || kids.contains("Lib"))
    }

    static func hasCacheDirSignature(_ dir: String) -> Bool {
        // Non-blocking and no symbolic links, so a pipe or link named CACHEDIR.TAG can't stall or redirect the read.
        let fd = open(dir + "/CACHEDIR.TAG", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
        let signature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)
        var head = [UInt8](repeating: 0, count: signature.count)
        let n = head.withUnsafeMutableBytes { read(fd, $0.baseAddress, signature.count) }
        return n == signature.count && head == signature
    }

    static let buildFolders: Set<String> = [".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular",
                                            ".expo", ".gradle", ".dart_tool"]

    func developer() -> CategoryResult {
        var items: [CleanupItem] = []
        let staleAfter = days(settings.staleProjectDays)
        let depNames = Set(["node_modules", ".venv", "venv", "target"]).union(Self.buildFolders)

        func projectTouched(_ project: NodeID) -> Date {
            var newest = tree.ownNewestModification(project)
            for c in tree.liveChildren(project) where !depNames.contains(tree.name(c)) && !tree.flags(c).contains(.pyvenv) {
                newest = max(newest, tree.newestModification(c))
            }
            return newest
        }

        func add(_ n: NodeID, kind: String, section: String, confidence: Confidence) {
            guard let project = tree.parent(n) else { return }
            let touched = projectTouched(project)
            let stale = now.timeIntervalSince(touched) > staleAfter
            let projectName = tree.name(project)
            if let i = folder(n, path: tree.path(n), title: projectName, section: section, confidence: confidence,
                              recommended: stale,
                              note: kind, date: touched, dateLabel: "Project Modified",
                              detail: AppPaths.abbreviate(tree.path(n)), minimum: 5_000_000) {
                items.append(i)
            }
        }

        var stack = userAreaRoots()
        while let n = stack.popLast() {
            let f = tree.flags(n)
            if f.contains(.removed) || f.contains(.package) { continue }
            let name = tree.name(n)
            let parentFlags = tree.parent(n).map { tree.flags($0) } ?? []
            if name == "node_modules" {
                if parentFlags.contains(.nodeProject) {
                    add(n, kind: "Restore with npm install", section: "Project Dependencies", confidence: .reinstall)
                }
                continue
            }
            if f.contains(.pyvenv) && Self.isVirtualEnvironment(n, in: tree) {
                add(n, kind: "Restore with python -m venv", section: "Project Dependencies", confidence: .reinstall)
                continue
            }
            // CACHEDIR.TAG marks a cache, but people also use it to keep folders out of backups:
            // only trust it inside a project, and only with the standard signature.
            if f.contains(.cacheTag) && !parentFlags.isDisjoint(with: [.cargoProject, .nodeProject, .gitRepo])
                && (AppPaths.isDemo || Self.hasCacheDirSignature(tree.path(n))) {
                add(n, kind: "Rebuilt on the next build", section: "Build Files", confidence: .rebuilds)
                continue
            }
            if Self.buildFolders.contains(name) && (parentFlags.contains(.nodeProject) || name == ".gradle" || name == ".dart_tool") {
                add(n, kind: "Rebuilt on the next build", section: "Build Files", confidence: .rebuilds)
                continue
            }
            if name == ".git" { continue }
            stack.append(contentsOf: tree.liveChildren(n))
        }

        let h = home
        let xcode: [(String, String, Confidence, Bool, String?)] = [
            ("/Library/Developer/Xcode/DerivedData", "Derived Data", .rebuilds, true, "Xcode build products"),
            ("/Library/Developer/Xcode/iOS DeviceSupport", "iOS Device Support", .rebuilds, true,
             "Copied again when a device connects"),
            ("/Library/Developer/Xcode/watchOS DeviceSupport", "watchOS Device Support", .rebuilds, true,
             "Copied again when a device connects"),
            ("/Library/Developer/Xcode/Archives", "Archives", .review, false, "Needed to symbolicate crash reports"),
            ("/Library/Developer/CoreSimulator/Caches", "Simulator Caches", .rebuilds, true, nil),
            ("/Library/Developer/CoreSimulator/Devices", "Simulator Devices", .review, false,
             "Includes the apps and data on each simulator"),
        ]
        for (rel, title, conf, rec, note) in xcode {
            if let i = folder(h + rel, title: title, section: "Xcode", confidence: conf,
                              recommended: rec, note: note) { items.append(i) }
        }
        for f in tree.bigFiles where !f.removed && f.name == "Docker.raw" {
            let path = tree.bigFilePath(f)
            guard path.hasPrefix(h + "/Library/Containers/com.docker.docker/") else { continue }
            items.append(CleanupItem(path: path, title: "Docker Disk Image", bytes: f.privateSize, confidence: .review,
                                     note: "Reduce its size in Docker Desktop settings instead",
                                     isDirectory: false, recommended: false, section: "Virtual Machines"))
        }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .developer, items: items,
                              sections: ["Project Dependencies", "Build Files", "Xcode", "Virtual Machines"])
    }

    // MARK: Large and old

    func largeOld() -> CategoryResult {
        var items: [CleanupItem] = []
        let cutoff = now.addingTimeInterval(-days(settings.unusedMonths * 30))
        let minimum = settings.largeFileMinimum
        let unusedSection = settings.unusedMonths % 12 == 0
            ? "Not Opened in \(settings.unusedMonths / 12) \(settings.unusedMonths == 12 ? "Year" : "Years")"
            : "Not Opened in \(settings.unusedMonths) Months"
        for f in tree.bigFiles where !f.removed && !f.isDataless && f.privateSize >= minimum {
            let path = tree.bigFilePath(f)
            guard inUserArea(path), !claimed.contains(path), RemovalGuard.refusal(for: path) == nil else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(f.modified))
            let added = Date(timeIntervalSince1970: TimeInterval(f.added))
            let used = Self.spotlightLastUsed(path)
            let last = max(modified, added, used ?? .distantPast)
            let old = last < cutoff
            guard old || f.privateSize >= minimum * 2 else { continue }
            items.append(CleanupItem(path: path, title: f.name, bytes: f.privateSize, confidence: .review,
                                     note: RemovalGuard.warning(for: path), date: last,
                                     dateLabel: used != nil && used! >= modified ? "Last Opened" : "Modified",
                                     isDirectory: false, recommended: false,
                                     section: old ? unusedSection : "Other Large Files"))
        }
        // Bundles that hold one thing, such as TV downloads and disk images.
        let bundleNotes = ["movpkg": "Remove downloads in the TV app", "sparsebundle": "Disk image",
                           "fcpbundle": "Final Cut Pro library", "imovielibrary": "iMovie library"]
        var stack = userAreaRoots()
        while let n = stack.popLast() {
            let f = tree.flags(n)
            if f.contains(.removed) { continue }
            let name = tree.name(n)
            let ext = (name as NSString).pathExtension.lowercased()
            if f.contains(.package) {
                if let note = bundleNotes[ext], tree.reclaimable(n) >= minimum / 2 {
                    let last = tree.newestModification(n)
                    let title = ext == "movpkg" ? (name as NSString).deletingPathExtension : name
                    if let i = folder(n, path: tree.path(n), title: title, section: ext == "movpkg" ? "TV App Downloads" : unusedSection,
                                      confidence: .review, recommended: false, note: note, date: last,
                                      dateLabel: "Modified") { items.append(i) }
                }
                continue
            }
            if name.hasPrefix(".") || name == "node_modules" { continue }
            stack.append(contentsOf: tree.liveChildren(n))
        }
        // Big folders nobody has touched in a long time, one or two levels into your folders.
        let quiet = now.addingTimeInterval(-days(settings.unusedMonths * 2 * 30))
        for root in userAreaRoots() {
            for n in [root] + tree.liveChildren(root) where n != root || tree.parent(root) != tree.node(at: home) {
                let name = tree.name(n)
                guard !name.hasPrefix("."), !tree.flags(n).contains(.package),
                      tree.reclaimable(n) >= minimum * 2, tree.newestModification(n) < quiet else { continue }
                let path = tree.path(n)
                guard !items.contains(where: { $0.path.hasPrefix(path + "/") || path.hasPrefix($0.path + "/") }) else { continue }
                if let i = folder(n, path: path, title: name, section: "Old Folders",
                                  confidence: .review, recommended: false, note: RemovalGuard.warning(for: path),
                                  date: tree.newestModification(n), dateLabel: "Modified") { items.append(i) }
            }
        }
        // Device backups made by Finder.
        let backups = home + "/Library/Application Support/MobileSync/Backup"
        if let b = tree.node(at: backups) {
            for c in tree.liveChildren(b) {
                let path = tree.path(c)
                let info = NSDictionary(contentsOfFile: path + "/Info.plist")
                let device = (info?["Device Name"] as? String) ?? "Device Backup"
                let date = (info?["Last Backup Date"] as? Date) ?? tree.newestModification(c)
                if let i = folder(c, path: path, title: device, section: "iPhone and iPad Backups", confidence: .review,
                                  recommended: false, note: "Backup made by Finder",
                                  date: date, dateLabel: "Backed Up") { items.append(i) }
            }
        }
        for i in items { claimed.insert(i.path) }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .largeOld, items: items,
                              sections: [unusedSection, "TV App Downloads", "Old Folders", "iPhone and iPad Backups",
                                         "Other Large Files"])
    }

    // MARK: Leftovers

    static let systemNames: Set<String> = [
        "addressbook", "animoji", "app store", "appstore", "accessibility", "callhistorydb", "callhistorytransactions",
        "clouddocs", "crashreporter", "diskimages", "dock", "facetime", "fileprovider", "knowledge", "mobilesync",
        "quick look", "syncservices", "ubiquity", "icloud", "icdd", "networkserviceproxy", "mail", "safari", "photos",
        "music", "tv", "podcasts", "books", "maps", "notes", "reminders", "calendars", "contacts", "siri", "shortcuts",
        "wallpaper", "wallpapers", "spotlight", "screentime", "differentialprivacy", "protectedcloudstorage", "cloudkit",
        "caches", "telemetry", "logs", "apple", "sharekit", "applemediaservices", "avatar", "identityservices",
        "family", "passkit", "familycircle", "askpermission", "homekit", "weather", "stocks", "news", "freeform",
        "journal", "passwords", "games", "preview", "voicememos", "textedit", "chrono", "callservices", "assistant",
        "com.apple.sharedfilelist", "keychain", "cloudstorage", "storeassets",
    ]

    func leftovers() -> CategoryResult {
        var items: [CleanupItem] = []
        let quietFor = days(90)
        let h = home

        func consider(_ n: NodeID, name rawName: String) {
            let path = tree.path(n)
            guard !claimed.contains(path) else { return }
            var name = rawName
            if name.hasSuffix(".savedState") { name = String(name.dropLast(".savedState".count)) }
            if name.hasPrefix("group.") { name = String(name.dropFirst(6)) }
            // Team-ID prefixes on group containers: "2BUA8C4S2C.com.agilebits".
            let parts = name.split(separator: ".", maxSplits: 1)
            if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                guard AppCatalog.looksLikeBundleID(String(parts[1])) else { return }
                name = String(parts[1])
            }
            let lower = name.lowercased()
            if lower.hasPrefix("com.apple.") || name.hasPrefix(".") || Self.systemNames.contains(lower) { return }
            let touched = tree.newestModification(n)
            guard now.timeIntervalSince(touched) > quietFor else { return }
            if UUID(uuidString: name) != nil { return }  // app extensions and system services
            if AppCatalog.looksLikeBundleID(name) {
                guard !catalog.isInstalled(bundleID: name), !catalog.vendorInstalled(name) else { return }
                // Same name as an installed app from another source (App Store vs. direct download): leave it.
                if let last = name.split(separator: ".").last, last.count >= 5,
                   catalog.matchesInstalledApp(folderName: String(last)) { return }
                if let i = folder(n, path: path, title: name, section: "Apps Not Installed", confidence: .review,
                                  recommended: false, note: "App not installed", date: touched,
                                  dateLabel: "Modified") { items.append(i) }
            } else {
                // Daemon folders such as "rtcreportingd" belong to macOS.
                if lower == name && lower.hasSuffix("d") { return }
                guard !catalog.matchesInstalledApp(folderName: name) else { return }
                if let i = folder(n, path: path, title: name, section: "Possibly Unused", confidence: .review,
                                  recommended: false, note: "No matching app found", date: touched,
                                  dateLabel: "Modified", minimum: 5_000_000) { items.append(i) }
            }
        }

        for rel in ["/Library/Application Support", "/Library/Containers", "/Library/Group Containers",
                    "/Library/Saved Application State", "/Library/HTTPStorages", "/Library/WebKit"] {
            guard let parent = tree.node(at: h + rel) else { continue }
            for c in tree.liveChildren(parent) where !tree.flags(c).contains(.protected) {
                consider(c, name: tree.name(c))
            }
        }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .leftovers, items: items, sections: ["Apps Not Installed", "Possibly Unused"])
    }
}

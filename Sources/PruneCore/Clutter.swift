import CoreServices
import Foundation

public enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case caches, downloads, developer, largeOld, duplicates, leftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caches: "Caches"
        case .downloads: "Downloads"
        case .developer: "Developer"
        case .largeOld: "Large and old"
        case .duplicates: "Duplicates"
        case .leftovers: "Leftovers"
        }
    }

    public var symbol: String {
        switch self {
        case .caches: "arrow.triangle.2.circlepath"
        case .downloads: "arrow.down.circle"
        case .developer: "hammer"
        case .largeOld: "shippingbox"
        case .duplicates: "square.on.square"
        case .leftovers: "puzzlepiece.extension"
        }
    }

    public var blurb: String {
        switch self {
        case .caches: "Temporary files apps and tools rebuild on their own."
        case .downloads: "Installers you've already used and files you haven't opened in months."
        case .developer: "Project dependencies, build output and Xcode data you can regenerate."
        case .largeOld: "Big files you haven't opened in a long time."
        case .duplicates: "Identical copies of the same file."
        case .leftovers: "Data from apps that are no longer installed."
        }
    }
}

/// How sure Prune is that an item can go.
public enum Confidence: Int, Sendable, Comparable {
    case safe, rebuilds, reinstall, review

    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .rebuilds: "Rebuilds itself"
        case .reinstall: "Reinstall to use"
        case .review: "You decide"
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
    let home = NSHomeDirectory()
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

    private func isRunning(folderName name: String) -> Bool {
        let lower = name.lowercased()
        if running.ids.contains(lower) { return true }
        if AppCatalog.looksLikeBundleID(name) {
            return running.ids.contains { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }
        }
        if running.names.contains(lower) { return true }
        return lower.count >= 4 && running.names.contains { $0.hasPrefix(lower + " ") }
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
                 note: "Models download again the next time a program needs them."),
            Tool(path: h + "/.gradle/caches", title: "Gradle cache"),
            Tool(path: h + "/.m2/repository", title: "Maven libraries", recommended: false),
            Tool(path: h + "/.cargo/registry", title: "Cargo registry"),
            Tool(path: h + "/go/pkg/mod", title: "Go modules"),
            Tool(path: h + "/Library/Caches/go-build", title: "Go build cache"),
            Tool(path: h + "/Library/Caches/CocoaPods", title: "CocoaPods cache"),
            Tool(path: h + "/Library/Caches/ms-playwright", title: "Playwright browsers", recommended: false,
                 note: "Playwright downloads them again on install."),
            Tool(path: h + "/.cache/puppeteer", title: "Puppeteer browsers", recommended: false),
            Tool(path: h + "/Library/Caches/JetBrains", title: "JetBrains caches"),
        ]
        for t in tools {
            if let i = folder(t.path, title: t.title, section: "Tool caches", confidence: t.confidence,
                              recommended: t.recommended, note: t.note) { items.append(i) }
        }
        // ~/.cache follows the XDG rule: anything inside can be deleted.
        if let xdg = tree.node(at: h + "/.cache") {
            for c in tree.liveChildren(xdg) {
                let name = tree.name(c)
                if let i = folder(c, path: tree.path(c), title: name, section: "Tool caches", confidence: .rebuilds,
                                  recommended: true) { items.append(i) }
            }
        }

        // ~/Library/Caches, one item per app.
        if let lib = tree.node(at: h + "/Library/Caches") {
            for c in tree.liveChildren(lib) {
                let name = tree.name(c)
                let apple = name.hasPrefix("com.apple.")
                let open = isRunning(folderName: name)
                let note: String? = open ? "\(catalog.displayName(forFolder: name)) is open. Quit it first." :
                    apple ? "Used by macOS. It rebuilds this, but you may notice some slowness at first." : nil
                if let i = folder(c, path: tree.path(c), title: catalog.displayName(forFolder: name), section: "App caches",
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
                let open = isRunning(folderName: name)
                if let i = folder(cache, path: tree.path(cache), title: catalog.displayName(forFolder: name),
                                  section: "App caches", confidence: .rebuilds, recommended: !open,
                                  note: open ? "The app is open. Quit it first." : nil,
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
                let open = isRunning(folderName: appName)
                var levels: [NodeID] = [app]
                levels += tree.liveChildren(app).filter { tree.childCount[Int($0)] > 0 }
                for parent in levels {
                    for c in tree.liveChildren(parent) where webCaches.contains(tree.name(c)) {
                        let label = parent == app ? appName : appName + " · " + tree.name(parent)
                        if let i = folder(c, path: tree.path(c), title: label + " · " + tree.name(c),
                                          section: "Web caches", confidence: .rebuilds, recommended: !open,
                                          note: open ? "\(appName) is open. Quit it first." : nil,
                                          minimum: 5_000_000) { items.append(i) }
                    }
                }
            }
        }
        if let i = folder(h + "/Library/Logs", title: "App logs", section: "Logs", confidence: .safe, recommended: true,
                          note: "Diagnostic logs. Apps start new ones as needed.", minimum: 5_000_000) {
            items.append(i)
        }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .caches, items: items, sections: ["App caches", "Tool caches", "Web caches", "Logs"])
    }

    // MARK: Downloads

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso", "tar", "gz", "tgz", "bz2",
                                                   "xz", "7z", "rar", "msi", "exe", "apk", "ipa", "crx"]

    func downloads() -> CategoryResult {
        let dir = home + "/Downloads"
        var items: [CleanupItem] = []
        let dirNode = tree.node(at: dir)
        let lister = BulkLister()
        lister.list(dir) { e in
            guard !e.isHidden, !e.isDataless else { return }
            let path = dir + "/" + e.name
            let ext = (e.name as NSString).pathExtension.lowercased()
            var bytes = e.reclaimable
            if e.kind == .directory {
                guard let d = dirNode, let n = tree.child(d, named: e.name) else { return }
                bytes = tree.reclaimable(n)
            }
            guard bytes >= 100_000, RemovalGuard.refusal(for: path) == nil else { return }
            let added = Date(timeIntervalSince1970: TimeInterval(e.added > 0 ? e.added : e.modified))
            let used = Self.spotlightLastUsed(path)
            let lastTouch = max(added, used ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(e.modified)))
            let age = now.timeIntervalSince(added)
            let idle = now.timeIntervalSince(lastTouch)
            if ["crdownload", "download", "part", "partial"].contains(ext) && age > days(1) {
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .safe,
                                         note: "A download that never finished.", date: added, dateLabel: "Added",
                                         isDirectory: e.kind == .directory, recommended: true, section: "Unfinished downloads"))
            } else if e.kind != .directory && Self.installerExtensions.contains(ext) && age > days(14) {
                let note = ["dmg", "pkg", "mpkg", "iso", "xip"].contains(ext) ? "Installer. Keep it only if you'll reinstall."
                    : "Archive. Delete it if you've already opened it."
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .safe, note: note,
                                         date: added, dateLabel: "Added", isDirectory: false,
                                         recommended: age > days(30), section: "Installers and archives"))
            } else if ext == "app" {
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .review,
                                         note: "An app that was never moved to Applications.", date: lastTouch,
                                         dateLabel: "Last used", isDirectory: true, recommended: false,
                                         iconPath: path, section: "Apps left in Downloads"))
            } else if idle > days(90) {
                items.append(CleanupItem(path: path, title: e.name, bytes: bytes, confidence: .review, note: nil,
                                         date: lastTouch, dateLabel: used != nil ? "Last opened" : "Added",
                                         isDirectory: e.kind == .directory, recommended: false,
                                         section: "Not opened in 3 months"))
            }
        }
        for i in items { claimed.insert(i.path) }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .downloads, items: items,
                              sections: ["Installers and archives", "Unfinished downloads", "Apps left in Downloads",
                                         "Not opened in 3 months"])
    }

    // MARK: Developer

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
                              note: stale ? kind : kind + " Project changed recently.",
                              date: touched, dateLabel: "Project changed",
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
                    add(n, kind: "Run npm install to bring it back.", section: "Project dependencies", confidence: .reinstall)
                }
                continue
            }
            if f.contains(.pyvenv) {
                add(n, kind: "Recreate it with python -m venv.", section: "Project dependencies", confidence: .reinstall)
                continue
            }
            if f.contains(.cacheTag) {
                add(n, kind: "Build output. Rebuilt by the next build.", section: "Build output", confidence: .rebuilds)
                continue
            }
            if Self.buildFolders.contains(name) && (parentFlags.contains(.nodeProject) || name == ".gradle" || name == ".dart_tool") {
                add(n, kind: "Build cache. Rebuilt by the next build.", section: "Build output", confidence: .rebuilds)
                continue
            }
            if name == ".git" { continue }
            stack.append(contentsOf: tree.liveChildren(n))
        }

        let h = home
        let xcode: [(String, String, Confidence, Bool, String?)] = [
            ("/Library/Developer/Xcode/DerivedData", "Xcode build products", .rebuilds, true, nil),
            ("/Library/Developer/Xcode/iOS DeviceSupport", "iOS device symbols", .rebuilds, true,
             "Copied again when you connect a device."),
            ("/Library/Developer/Xcode/watchOS DeviceSupport", "watchOS device symbols", .rebuilds, true, nil),
            ("/Library/Developer/Xcode/Archives", "Xcode archives", .review, false,
             "Needed to read crash reports from apps you shipped."),
            ("/Library/Developer/CoreSimulator/Caches", "Simulator caches", .rebuilds, true, nil),
            ("/Library/Developer/CoreSimulator/Devices", "Simulator devices", .review, false,
             "Simulators and the apps on them. Xcode can recreate the devices."),
        ]
        for (rel, title, conf, rec, note) in xcode {
            if let i = folder(h + rel, title: title, section: "Xcode and simulators", confidence: conf,
                              recommended: rec, note: note) { items.append(i) }
        }
        for f in tree.bigFiles where !f.removed && f.name == "Docker.raw" {
            let path = tree.bigFilePath(f)
            guard path.hasPrefix(h + "/Library/Containers/com.docker.docker/") else { continue }
            items.append(CleanupItem(path: path, title: "Docker disk image", bytes: f.privateSize, confidence: .review,
                                     note: "Shrink it from Docker Desktop instead: Settings → Resources, or prune images.",
                                     isDirectory: false, recommended: false, section: "Virtual machines"))
        }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .developer, items: items,
                              sections: ["Project dependencies", "Build output", "Xcode and simulators", "Virtual machines"])
    }

    // MARK: Large and old

    func largeOld() -> CategoryResult {
        var items: [CleanupItem] = []
        let cutoff = now.addingTimeInterval(-days(settings.unusedMonths * 30))
        let minimum = settings.largeFileMinimum
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
                                     dateLabel: used != nil && used! >= modified ? "Last opened" : "Modified",
                                     isDirectory: false, recommended: false,
                                     section: old ? "Not opened in \(settings.unusedMonths) months" : "Other large files"))
        }
        // Bundles that hold one thing, such as TV downloads and disk images.
        let bundleNotes = ["movpkg": "Downloaded in the TV app. Removing it there keeps the library tidy.",
                           "sparsebundle": "A disk image.", "fcpbundle": "A Final Cut Pro library.",
                           "imovielibrary": "An iMovie library."]
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
                    if let i = folder(n, path: tree.path(n), title: title, section: ext == "movpkg" ? "TV downloads" : "Not opened in \(settings.unusedMonths) months",
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
                if let i = folder(n, path: path, title: name, section: "Folders untouched for a year",
                                  confidence: .review, recommended: false, note: RemovalGuard.warning(for: path),
                                  date: tree.newestModification(n), dateLabel: "Last changed") { items.append(i) }
            }
        }
        // Device backups made by Finder.
        let backups = home + "/Library/Application Support/MobileSync/Backup"
        if let b = tree.node(at: backups) {
            for c in tree.liveChildren(b) {
                let path = tree.path(c)
                let info = NSDictionary(contentsOfFile: path + "/Info.plist")
                let device = (info?["Device Name"] as? String) ?? "Device backup"
                let date = (info?["Last Backup Date"] as? Date) ?? tree.newestModification(c)
                if let i = folder(c, path: path, title: device, section: "Device backups", confidence: .review,
                                  recommended: false, note: "A backup of an iPhone or iPad. Keep your newest one.",
                                  date: date, dateLabel: "Backed up") { items.append(i) }
            }
        }
        for i in items { claimed.insert(i.path) }
        items.sort { $0.bytes > $1.bytes }
        return CategoryResult(category: .largeOld, items: items,
                              sections: ["Not opened in \(settings.unusedMonths) months", "TV downloads", "Folders untouched for a year",
                                         "Device backups", "Other large files"])
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
                if let i = folder(n, path: path, title: name, section: "Apps you no longer have", confidence: .review,
                                  recommended: false, note: "No installed app uses this.", date: touched,
                                  dateLabel: "Last changed") { items.append(i) }
            } else {
                // Daemon folders such as "rtcreportingd" belong to macOS.
                if lower == name && lower.hasSuffix("d") { return }
                guard !catalog.matchesInstalledApp(folderName: name) else { return }
                if let i = folder(n, path: path, title: name, section: "Possibly unused", confidence: .review,
                                  recommended: false, note: "No installed app matches this name.", date: touched,
                                  dateLabel: "Last changed", minimum: 5_000_000) { items.append(i) }
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
        return CategoryResult(category: .leftovers, items: items, sections: ["Apps you no longer have", "Possibly unused"])
    }
}

import Foundation
import Synchronization

/// Live numbers from a running scan, safe to read from any thread.
public final class ScanProgress: Sendable {
    public let files = Atomic<Int>(0)
    public let folders = Atomic<Int>(0)
    public let bytes = Atomic<Int64>(0)
    let currentPath = Mutex<String>("")

    public init() {}

    public var current: String { currentPath.withLock { $0 } }
}

/// Walks a folder tree in parallel and builds a `FileTree`.
public final class Scanner: @unchecked Sendable {
    public struct Options: Sendable {
        public var root: String
        public var excluded: Set<String>
        public var threads: Int
        public var privateSizes: Bool

        public init(root: String, excluded: Set<String> = [], threads: Int = 0, privateSizes: Bool = true) {
            self.root = root
            self.excluded = excluded
            self.threads = threads > 0 ? threads : max(4, ProcessInfo.processInfo.activeProcessorCount)
            self.privateSizes = privateSizes
        }
    }

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "prefpane", "saver", "qlgenerator",
        "mdimporter", "component", "vst", "vst3", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary",
        "aplibrary", "fcpbundle", "imovielibrary", "logicx", "band", "rtfd", "pages", "numbers", "key",
        "sparsebundle", "dsym", "xcarchive", "playground", "scptd", "workflow", "pkg", "mpkg", "lrlibrary",
        "lrcat-data", "theater", "migratedphotolibrary", "abbu", "wdgt", "docset", "xcassets", "car", "movpkg",
    ]

    /// Special folders at the top of the startup disk that alias other places or hold other volumes.
    static let rootSkips: Set<String> = [
        "/.vol", "/.nofollow", "/.resolve", "/dev", "/net", "/home", "/Volumes", "/System/Volumes",
    ]

    public let options: Options
    public let progress = ScanProgress()
    private let cancelled = Atomic<Bool>(false)

    private let tree: FileTree
    private let treeLock = NSLock()
    private let queue = NSCondition()
    private var stack: [(NodeID, String)] = []
    private var active = 0
    private let hardLinks = Mutex<Set<HardLinkKey>>([])

    private struct HardLinkKey: Hashable { let device: Int32; let file: UInt64 }

    public init(options: Options) {
        self.options = options
        tree = FileTree(rootPath: options.root)
    }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Scans synchronously on `options.threads` threads. Returns nil if cancelled.
    public func run() -> FileTree? {
        let started = Date()
        stack = [(tree.root, options.root)]
        let group = DispatchGroup()
        for _ in 0..<options.threads {
            group.enter()
            let thread = Thread { [self] in
                worker()
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        if isCancelled { return nil }
        tree.computeTotals()
        tree.scanDate = started
        tree.scanDuration = Date().timeIntervalSince(started)
        return tree
    }

    private func worker() {
        let lister = BulkLister(privateSizes: options.privateSizes)
        while true {
            queue.lock()
            while stack.isEmpty && active > 0 && !isCancelled { queue.wait() }
            if stack.isEmpty || isCancelled {
                queue.broadcast()
                queue.unlock()
                return
            }
            let (node, path) = stack.removeLast()
            active += 1
            queue.unlock()

            let next = process(node: node, path: path, lister: lister)

            queue.lock()
            stack.append(contentsOf: next)
            active -= 1
            if !next.isEmpty || active == 0 { queue.broadcast() }
            queue.unlock()
        }
    }

    private struct Subdir {
        var name: String
        var flags: NodeFlags
        var modified: UInt32
        var descend: Bool
    }

    private func process(node: NodeID, path: String, lister: BulkLister) -> [(NodeID, String)] {
        var subdirs: [Subdir] = []
        var big: [BigFile] = []
        var alloc: Int64 = 0, priv: Int64 = 0, cloud: Int64 = 0
        var files: Int32 = 0
        var newest: UInt32 = 0
        var marks: NodeFlags = []
        let prefix = path == "/" ? "/" : path + "/"

        let err = lister.list(path) { e in
            let modified = UInt32(clamping: max(0, e.modified))
            switch e.kind {
            case .directory:
                var flags: NodeFlags = []
                var descend = true
                let lower = e.name.lowercased()
                if let dot = lower.lastIndex(of: "."), Self.packageExtensions.contains(String(lower[lower.index(after: dot)...])) {
                    flags.insert(.package)
                }
                if e.name == ".git" { marks.insert(.gitRepo) }
                if e.isMountPoint || (options.root == "/" && Self.rootSkips.contains(prefix + e.name)) {
                    flags.insert(.mountPoint)
                    descend = false
                } else if e.isDataless {
                    flags.insert(.cloudOnly)
                    descend = false
                } else if !options.excluded.isEmpty && options.excluded.contains(prefix + e.name) {
                    flags.insert(.excluded)
                    descend = false
                }
                subdirs.append(Subdir(name: e.name, flags: flags, modified: modified, descend: descend))
            default:
                var a = e.allocated
                var pv = e.reclaimable
                if e.kind == .file && e.linkCount > 1 {
                    let key = HardLinkKey(device: e.device, file: e.fileID)
                    let first = hardLinks.withLock { $0.insert(key).inserted }
                    if !first { a = 0; pv = 0 }
                }
                files += 1
                alloc += a
                priv += pv
                if e.isDataless { cloud += e.logical }
                if modified > newest { newest = modified }
                switch e.name {
                case "CACHEDIR.TAG": marks.insert(.cacheTag)
                case "pyvenv.cfg": marks.insert(.pyvenv)
                case "package.json": marks.insert(.nodeProject)
                case "Cargo.toml": marks.insert(.cargoProject)
                default: break
                }
                if e.kind == .file && (e.logical >= FileTree.bigFileThreshold || a >= FileTree.bigFileThreshold) {
                    big.append(BigFile(
                        dir: node, name: e.name, logical: e.logical, allocated: a, privateSize: pv,
                        modified: modified, accessed: UInt32(clamping: max(0, e.accessed)),
                        added: UInt32(clamping: max(0, e.added)), isDataless: e.isDataless))
                }
            }
        }
        if err == EPERM { marks.insert(.protected) }
        else if err == EACCES { marks.insert(.unreadable) }

        progress.files.add(Int(files), ordering: .relaxed)
        progress.bytes.add(alloc, ordering: .relaxed)
        if progress.folders.add(1, ordering: .relaxed).newValue % 512 == 0 {
            progress.currentPath.withLock { $0 = path }
        }

        var next: [(NodeID, String)] = []
        next.reserveCapacity(subdirs.count)
        treeLock.lock()
        let start = NodeID(tree.count)
        for s in subdirs {
            let id = tree.append(parent: node, name: s.name, flags: s.flags, modified: s.modified)
            if s.descend { next.append((id, prefix + s.name)) }
        }
        let i = Int(node)
        tree.childStart[i] = start
        tree.childCount[i] = Int32(subdirs.count)
        tree.flagBits[i] |= marks.rawValue
        tree.ownAlloc[i] = alloc
        tree.ownPrivate[i] = priv
        tree.ownCloud[i] = cloud
        tree.ownFiles[i] = files
        if newest > tree.ownNewest[i] { tree.ownNewest[i] = newest }
        tree.bigFiles.append(contentsOf: big)
        treeLock.unlock()
        return next
    }
}

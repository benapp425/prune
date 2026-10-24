import Foundation

public typealias NodeID = Int32

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// An app, library or other bundle that Finder shows as a single file.
    public static let package = NodeFlags(rawValue: 1 << 0)
    /// Holds a CACHEDIR.TAG file: a cache by the standard tools follow.
    public static let cacheTag = NodeFlags(rawValue: 1 << 1)
    /// Holds pyvenv.cfg: a Python virtual environment.
    public static let pyvenv = NodeFlags(rawValue: 1 << 2)
    /// Couldn't be read (file permissions).
    public static let unreadable = NodeFlags(rawValue: 1 << 3)
    /// Blocked by macOS privacy protection: needs Full Disk Access.
    public static let protected = NodeFlags(rawValue: 1 << 4)
    /// Another volume is mounted here; not scanned.
    public static let mountPoint = NodeFlags(rawValue: 1 << 5)
    /// An offloaded folder: its contents live in the cloud and listing it would download them.
    public static let cloudOnly = NodeFlags(rawValue: 1 << 6)
    /// Moved to the Trash since the scan.
    public static let removed = NodeFlags(rawValue: 1 << 7)
    /// Skipped because it's in the exclusion list.
    public static let excluded = NodeFlags(rawValue: 1 << 8)
    /// Holds a .git folder.
    public static let gitRepo = NodeFlags(rawValue: 1 << 9)
    /// Holds package.json.
    public static let nodeProject = NodeFlags(rawValue: 1 << 10)
    /// Holds Cargo.toml.
    public static let cargoProject = NodeFlags(rawValue: 1 << 11)

    /// Folders whose contents the scan never saw.
    public static let notScanned: NodeFlags = [.unreadable, .protected, .mountPoint, .cloudOnly, .excluded]
}

/// A file of 1 MB or more, kept so duplicate and large-file searches don't need another pass over the disk.
public struct BigFile: Sendable {
    public var dir: NodeID
    public var name: String
    public var logical: Int64
    public var allocated: Int64
    public var privateSize: Int64
    public var modified: UInt32
    public var accessed: UInt32
    public var added: UInt32
    public var isDataless: Bool
    public var removed = false
    /// The folder whose removal hid this file, or -1 if the file itself was removed.
    public var removedWith: NodeID = -1
}

/// The folder tree from a scan. Files are summed into their folder; only files of 1 MB or more are kept
/// one by one (in `bigFiles`). Children of a folder sit next to each other, always after their parent.
public final class FileTree: @unchecked Sendable {
    public static let bigFileThreshold: Int64 = 1_000_000

    public internal(set) var rootPath: String
    public internal(set) var scanDate = Date()
    public internal(set) var scanDuration: TimeInterval = 0

    var parent: [NodeID] = []
    var names: [String] = []
    var childStart: [NodeID] = []
    var childCount: [Int32] = []
    var flagBits: [UInt16] = []
    var ownAlloc: [Int64] = []
    var ownPrivate: [Int64] = []
    var ownCloud: [Int64] = []
    var ownFiles: [Int32] = []
    var ownNewest: [UInt32] = []
    var totalAlloc: [Int64] = []
    var totalPrivate: [Int64] = []
    var totalCloud: [Int64] = []
    var totalFiles: [Int64] = []
    var subtreeNewest: [UInt32] = []
    public internal(set) var bigFiles: [BigFile] = []

    public init(rootPath: String) {
        self.rootPath = rootPath
        _ = append(parent: -1, name: rootPath, flags: [], modified: 0)
    }

    public var count: Int { names.count }
    public var root: NodeID { 0 }

    func append(parent p: NodeID, name: String, flags: NodeFlags, modified: UInt32) -> NodeID {
        let id = NodeID(names.count)
        parent.append(p)
        names.append(name)
        childStart.append(0)
        childCount.append(0)
        flagBits.append(flags.rawValue)
        ownAlloc.append(0)
        ownPrivate.append(0)
        ownCloud.append(0)
        ownFiles.append(0)
        ownNewest.append(modified)
        return id
    }

    /// Sums every folder's files into its ancestors. Children always come after their parent,
    /// so one pass from the end is enough.
    func computeTotals() {
        totalAlloc = ownAlloc
        totalPrivate = ownPrivate
        totalCloud = ownCloud
        totalFiles = ownFiles.map { Int64($0) }
        subtreeNewest = ownNewest
        let removed = NodeFlags.removed.rawValue
        for i in stride(from: names.count - 1, to: 0, by: -1) where flagBits[i] & removed == 0 {
            let p = Int(parent[i])
            totalAlloc[p] += totalAlloc[i]
            totalPrivate[p] += totalPrivate[i]
            totalCloud[p] += totalCloud[i]
            totalFiles[p] += totalFiles[i]
            if subtreeNewest[i] > subtreeNewest[p] { subtreeNewest[p] = subtreeNewest[i] }
        }
    }

    // MARK: Reading

    public func name(_ n: NodeID) -> String { names[Int(n)] }
    public func parent(_ n: NodeID) -> NodeID? { let p = parent[Int(n)]; return p < 0 ? nil : p }
    public func flags(_ n: NodeID) -> NodeFlags { NodeFlags(rawValue: flagBits[Int(n)]) }
    public func size(_ n: NodeID) -> Int64 { totalAlloc[Int(n)] }
    /// Bytes you'd get back by deleting this folder: shared APFS clone blocks don't count.
    public func reclaimable(_ n: NodeID) -> Int64 { totalPrivate[Int(n)] }
    public func cloudBytes(_ n: NodeID) -> Int64 { totalCloud[Int(n)] }
    public func fileCount(_ n: NodeID) -> Int64 { totalFiles[Int(n)] }
    public func ownSize(_ n: NodeID) -> Int64 { ownAlloc[Int(n)] }
    public func ownFileCount(_ n: NodeID) -> Int { Int(ownFiles[Int(n)]) }
    public func newestModification(_ n: NodeID) -> Date {
        Date(timeIntervalSince1970: TimeInterval(subtreeNewest[Int(n)]))
    }
    public func ownNewestModification(_ n: NodeID) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ownNewest[Int(n)]))
    }

    public func children(_ n: NodeID) -> Range<NodeID> {
        let start = childStart[Int(n)]
        return start..<(start + childCount[Int(n)])
    }

    public func liveChildren(_ n: NodeID) -> [NodeID] {
        children(n).filter { !flags($0).contains(.removed) }
    }

    public func child(_ n: NodeID, named name: String) -> NodeID? {
        children(n).first { names[Int($0)] == name && !flags($0).contains(.removed) }
    }

    public func path(_ n: NodeID) -> String {
        var parts: [String] = []
        var cur = n
        while cur > 0 {
            parts.append(names[Int(cur)])
            cur = parent[Int(cur)]
        }
        let base = rootPath == "/" ? "" : rootPath
        if parts.isEmpty { return rootPath }
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    public func url(_ n: NodeID) -> URL { URL(fileURLWithPath: path(n)) }

    /// Finds the folder at an absolute path, if the scan saw it.
    public func node(at path: String) -> NodeID? {
        let clean = (path as NSString).standardizingPath
        if clean == rootPath { return root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard clean.hasPrefix(prefix) else { return nil }
        var cur = root
        for part in clean.dropFirst(prefix.count).split(separator: "/") {
            guard let next = child(cur, named: String(part)) else { return nil }
            cur = next
        }
        return cur
    }

    public func ancestors(_ n: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var cur = n
        while cur >= 0 {
            out.append(cur)
            cur = parent[Int(cur)]
        }
        return out.reversed()
    }

    public func isAncestor(_ a: NodeID, of n: NodeID) -> Bool {
        var cur = parent[Int(n)]
        while cur >= 0 {
            if cur == a { return true }
            cur = parent[Int(cur)]
        }
        return false
    }

    /// Every folder whose name matches, skipping matches nested inside an earlier match.
    public func topmost(where match: (NodeID) -> Bool) -> [NodeID] {
        var out: [NodeID] = []
        var stack: [NodeID] = [root]
        while let n = stack.popLast() {
            if n != root && match(n) {
                out.append(n)
                continue
            }
            let f = flags(n)
            if f.contains(.removed) { continue }
            stack.append(contentsOf: children(n))
        }
        return out
    }

    // MARK: Changes after a scan

    /// Marks a folder as moved to the Trash and takes its size off its ancestors.
    public func markRemoved(_ n: NodeID) {
        guard !flags(n).contains(.removed) else { return }
        flagBits[Int(n)] |= NodeFlags.removed.rawValue
        adjust(from: parent[Int(n)], alloc: -totalAlloc[Int(n)], priv: -totalPrivate[Int(n)],
               cloud: -totalCloud[Int(n)], files: -totalFiles[Int(n)])
        for i in bigFiles.indices where !bigFiles[i].removed {
            let d = bigFiles[i].dir
            if d == n || isAncestor(n, of: d) {
                bigFiles[i].removed = true
                bigFiles[i].removedWith = n
            }
        }
    }

    /// Puts a folder back after it was restored from the Trash.
    public func unmarkRemoved(_ n: NodeID) {
        guard flags(n).contains(.removed) else { return }
        flagBits[Int(n)] &= ~NodeFlags.removed.rawValue
        adjust(from: parent[Int(n)], alloc: totalAlloc[Int(n)], priv: totalPrivate[Int(n)],
               cloud: totalCloud[Int(n)], files: totalFiles[Int(n)])
        // Only files hidden by this folder's removal; files trashed on their own stay removed.
        for i in bigFiles.indices where bigFiles[i].removed && bigFiles[i].removedWith == n {
            bigFiles[i].removed = false
            bigFiles[i].removedWith = -1
        }
    }

    /// Takes a single file's size off its folder and that folder's ancestors. The amount is capped at what the
    /// folder's own files add up to, so a file the scan never counted can't push totals below zero.
    public func removeFile(in dir: NodeID, named name: String, allocated: Int64, privateSize: Int64) {
        let i = Int(dir)
        let alloc = min(max(0, allocated), ownAlloc[i])
        let priv = min(max(0, privateSize), ownPrivate[i])
        adjust(from: dir, alloc: -alloc, priv: -priv, cloud: 0, files: ownFiles[i] > 0 ? -1 : 0)
        ownAlloc[i] -= alloc
        ownPrivate[i] -= priv
        ownFiles[i] = max(0, ownFiles[i] - 1)
        if let i = bigFiles.firstIndex(where: { $0.dir == dir && $0.name == name && !$0.removed }) {
            bigFiles[i].removed = true
        }
    }

    public func restoreFile(in dir: NodeID, named name: String, allocated: Int64, privateSize: Int64) {
        adjust(from: dir, alloc: allocated, priv: privateSize, cloud: 0, files: 1)
        ownAlloc[Int(dir)] += allocated
        ownPrivate[Int(dir)] += privateSize
        ownFiles[Int(dir)] += 1
        if let i = bigFiles.firstIndex(where: { $0.dir == dir && $0.name == name && $0.removed }) {
            bigFiles[i].removed = false
        }
    }

    private func adjust(from start: NodeID, alloc: Int64, priv: Int64, cloud: Int64, files: Int64) {
        var cur = start
        while cur >= 0 {
            let i = Int(cur)
            totalAlloc[i] = max(0, totalAlloc[i] + alloc)
            totalPrivate[i] = max(0, totalPrivate[i] + priv)
            totalCloud[i] = max(0, totalCloud[i] + cloud)
            totalFiles[i] = max(0, totalFiles[i] + files)
            cur = parent[i]
        }
    }

    public func bigFilePath(_ f: BigFile) -> String {
        let dir = path(f.dir)
        return dir == "/" ? "/" + f.name : dir + "/" + f.name
    }
}

import Foundation

/// Saves the last scan so the app opens with results instead of an empty window.
public enum ScanCache {
    private static let magic: UInt32 = 0x5052_4E34  // "PRN4"

    public static var defaultURL: URL {
        AppPaths.support.appendingPathComponent("last-scan.bin")
    }

    public static func save(_ tree: FileTree, to url: URL = defaultURL) throws {
        var w = Writer()
        w.put(magic)
        w.put(tree.rootPath)
        w.put(tree.scanDate.timeIntervalSince1970)
        w.put(tree.scanDuration)
        w.put(UInt32(tree.count))
        w.putArray(tree.parent)
        w.putArray(tree.childStart)
        w.putArray(tree.childCount)
        w.putArray(tree.flagBits)
        w.putArray(tree.ownAlloc)
        w.putArray(tree.ownPrivate)
        w.putArray(tree.ownCloud)
        w.putArray(tree.ownFiles)
        w.putArray(tree.ownNewest)
        for name in tree.names { w.put(name) }
        w.put(UInt32(tree.bigFiles.count))
        for f in tree.bigFiles {
            w.put(f.dir)
            w.put(f.name)
            w.put(f.logical)
            w.put(f.allocated)
            w.put(f.privateSize)
            w.put(f.modified)
            w.put(f.accessed)
            w.put(f.added)
            w.put(UInt8((f.isDataless ? 1 : 0) | (f.removed ? 2 : 0)))
            w.put(f.removedWith)
        }
        try AppPaths.writePrivately(w.data, to: url)
    }

    public static func load(from url: URL = defaultURL) -> FileTree? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var r = Reader(data: data)
        guard (try? r.get(UInt32.self)) == magic else { return nil }
        do {
            let tree = FileTree(rootPath: try r.getString())
            tree.scanDate = Date(timeIntervalSince1970: try r.get(Double.self))
            tree.scanDuration = try r.get(Double.self)
            let n = Int(try r.get(UInt32.self))
            tree.parent = try r.getArray(n)
            tree.childStart = try r.getArray(n)
            tree.childCount = try r.getArray(n)
            tree.flagBits = try r.getArray(n)
            tree.ownAlloc = try r.getArray(n)
            tree.ownPrivate = try r.getArray(n)
            tree.ownCloud = try r.getArray(n)
            tree.ownFiles = try r.getArray(n)
            tree.ownNewest = try r.getArray(n)
            var names: [String] = []
            names.reserveCapacity(n)
            for _ in 0..<n { names.append(try r.getString()) }
            tree.names = names
            let bigCount = Int(try r.get(UInt32.self))
            var big: [BigFile] = []
            big.reserveCapacity(min(bigCount, 1_000_000))
            for _ in 0..<bigCount {
                let dir = try r.get(NodeID.self)
                let name = try r.getString()
                var f = BigFile(dir: dir, name: name, logical: try r.get(Int64.self), allocated: try r.get(Int64.self),
                                privateSize: try r.get(Int64.self), modified: try r.get(UInt32.self),
                                accessed: try r.get(UInt32.self), added: try r.get(UInt32.self), isDataless: false)
                let bits = try r.get(UInt8.self)
                f.isDataless = bits & 1 != 0
                f.removed = bits & 2 != 0
                f.removedWith = try r.get(NodeID.self)
                big.append(f)
            }
            tree.bigFiles = big
            // Any program running as you can write this file, so check it before using it.
            guard tree.isWellFormed() else { return nil }
            tree.computeTotals()
            return tree
        } catch {
            return nil
        }
    }

    private struct Writer {
        var data = Data()
        mutating func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func put(_ v: Double) { put(v.bitPattern) }
        mutating func put(_ s: String) {
            let bytes = Array(s.utf8)
            put(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
        mutating func putArray<T: FixedWidthInteger>(_ a: [T]) {
            a.withUnsafeBytes { data.append(contentsOf: $0) }
        }
    }

    private struct Reader {
        struct Truncated: Error {}
        let data: Data
        var offset = 0
        init(data: Data) { self.data = data }

        mutating func get<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw Truncated() }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return T(littleEndian: v)
        }
        mutating func get(_: Double.Type) throws -> Double { Double(bitPattern: try get(UInt64.self)) }
        mutating func getString() throws -> String {
            let n = Int(try get(UInt32.self))
            guard offset + n <= data.count else { throw Truncated() }
            let s = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + n], as: UTF8.self)
            offset += n
            return s
        }
        mutating func getArray<T: FixedWidthInteger>(_ n: Int) throws -> [T] {
            let size = n * MemoryLayout<T>.stride
            guard offset + size <= data.count else { throw Truncated() }
            let out = [T](unsafeUninitializedCapacity: n) { buf, count in
                data.withUnsafeBytes { raw in
                    UnsafeMutableRawBufferPointer(buf).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + size]))
                }
                count = n
            }
            offset += size
            return out
        }
    }
}

public enum AppPaths {
    /// The home folder of the account running Prune, from the user database. HOME and CFFIXED_USER_HOME
    /// aren't used: whatever launches Prune can set them.
    static let accountHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    /// The home folder Prune works in. In builds made for screenshots (PRUNE_HOOKS), PRUNE_HOME stands in for it.
    public static let home: String = {
        #if PRUNE_HOOKS
        if let demo = ProcessInfo.processInfo.environment["PRUNE_HOME"] { return demo }
        #endif
        return accountHome
    }()

    /// The demo with made-up files, used for screenshots. Only builds made with PRUNE_HOOKS have it.
    public static var isDemo: Bool {
        #if PRUNE_HOOKS
        return ProcessInfo.processInfo.environment["PRUNE_DEMO"] == "1"
        #else
        return false
        #endif
    }

    public static var support: URL {
        URL(fileURLWithPath: accountHome + "/Library/Application Support/Prune", isDirectory: true)
    }

    /// Writes a file only this user account can read: scan results name files macOS keeps private.
    static func writePrivately(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    /// Replaces the home folder with ~ for display.
    public static func abbreviate(_ path: String) -> String {
        let h = home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}

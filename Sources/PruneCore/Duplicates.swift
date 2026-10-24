import CryptoKit
import Foundation
import Synchronization

/// Finds identical files among the scan's big files: same size, then the same first and last 64 KB,
/// then the same SHA-256. Offloaded files are skipped so nothing gets downloaded.
public final class DuplicateFinder: @unchecked Sendable {
    public let minimum: Int64
    private let cancelled = Atomic<Bool>(false)
    /// Fraction done, 0...1000.
    public let progress = Atomic<Int>(0)

    public init(minimum: Int64 = 1_000_000) { self.minimum = minimum }

    static let toolFolders: Set<String> = ["node_modules", "site-packages", "dist-packages", "anaconda3", "miniconda3",
                                           "miniforge3", "DerivedData", "Pods", "vendor", "target", "build", "venv",
                                           "__pycache__", "bower_components", "Carthage"]
    static let codeExtensions: Set<String> = ["dylib", "so", "a", "o", "js", "mjs", "cjs", "map", "ts", "swiftmodule",
                                              "pyc", "jar", "class", "node", "wasm", "dll", "pdb", "lib",
                                              "pak", "asar", "db", "sqlite", "idx", "pack"]

    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    public struct Candidate: Sendable { let path: String; let file: BigFile }

    public func run(tree: FileTree) -> CategoryResult? { run(candidates: Self.candidates(tree: tree)) }

    /// The files worth comparing. Reads the tree, so call it while nothing changes the tree.
    public static func candidates(tree: FileTree, minimum: Int64 = 1_000_000) -> [Candidate] {
        let home = AppPaths.home
        func eligible(_ path: String) -> Bool {
            if path.hasPrefix("/Users/Shared/") { return !RemovalGuard.insidePackage(path) }
            guard path.hasPrefix(home + "/") else { return false }
            let rel = path.dropFirst(home.count + 1)
            if rel.hasPrefix("Library/") { return false }
            // Copies inside projects and toolchains are there on purpose.
            for part in rel.split(separator: "/").dropLast() where part.hasPrefix(".") || Self.toolFolders.contains(String(part)) {
                return false
            }
            if Self.codeExtensions.contains((path as NSString).pathExtension.lowercased()) { return false }
            return !RemovalGuard.insidePackage(path) && RemovalGuard.refusal(for: path) == nil
        }

        var out: [Candidate] = []
        for f in tree.bigFiles where !f.removed && !f.isDataless && f.logical >= minimum && f.allocated > 0 {
            let path = tree.bigFilePath(f)
            if eligible(path) { out.append(Candidate(path: path, file: f)) }
        }
        return out
    }

    /// Hashes candidates that share a size. Doesn't touch the tree. Returns nil if cancelled.
    public func run(candidates: [Candidate]) -> CategoryResult? {
        var bySize: [Int64: [Candidate]] = [:]
        for c in candidates { bySize[c.file.logical, default: []].append(c) }
        let groups = bySize.values.filter { $0.count > 1 }
        let totalWork = max(1, groups.reduce(0) { $0 + $1.count })
        var done = 0

        var found: [[Candidate]] = []
        for group in groups {
            if cancelled.load(ordering: .relaxed) { return nil }
            var byEdge: [Data: [Candidate]] = [:]
            for c in group {
                if let key = Self.edgeHash(c.path, size: c.file.logical) { byEdge[key, default: []].append(c) }
            }
            for edgeGroup in byEdge.values where edgeGroup.count > 1 {
                if edgeGroup[0].file.logical <= 131_072 {
                    found.append(edgeGroup)  // the edges already covered the whole file
                    continue
                }
                var byHash: [Data: [Candidate]] = [:]
                for c in edgeGroup {
                    if cancelled.load(ordering: .relaxed) { return nil }
                    if let key = Self.fullHash(c.path, cancelled: cancelled) { byHash[key, default: []].append(c) }
                }
                found += byHash.values.filter { $0.count > 1 }
            }
            done += group.count
            progress.store(done * 1000 / totalWork, ordering: .relaxed)
        }

        // Files may have been moved to the Trash while hashing ran.
        found = found.map { $0.filter { FileManager.default.fileExists(atPath: $0.path) } }.filter { $0.count > 1 }
        var items: [CleanupItem] = []
        var reclaimable: Int64 = 0
        var groupID = 0
        var gains: [Int: Int64] = [:]
        for set in found.sorted(by: { $0[0].file.logical * Int64($0.count) > $1[0].file.logical * Int64($1.count) }) {
            // Copies that are APFS clones share their blocks, so deleting one frees little.
            let sorted = set.sorted { $0.file.modified < $1.file.modified }
            // Storage the group really uses: each copy's own blocks, plus the blocks APFS clones share (once).
            // One full copy stays.
            let own = sorted.reduce(Int64(0)) { $0 + $1.file.privateSize }
            let shared = sorted.map { $0.file.allocated - $0.file.privateSize }.max() ?? 0
            let gain = own + shared - sorted[0].file.allocated
            guard gain >= 100_000 else { continue }
            reclaimable += gain
            gains[groupID] = gain
            let section = "\(set[0].file.name) — \(set.count) copies, \(Bytes.format(set[0].file.logical)) each"
            for c in sorted {
                items.append(CleanupItem(path: c.path, title: c.file.name, detail: AppPaths.abbreviate((c.path as NSString).deletingLastPathComponent),
                                         bytes: c.file.privateSize, confidence: .safe,
                                         note: c.file.privateSize < c.file.allocated / 2 ? "Shares storage with another copy" : nil,
                                         date: Date(timeIntervalSince1970: TimeInterval(c.file.modified)),
                                         dateLabel: "Modified", isDirectory: false, recommended: false,
                                         section: section, group: groupID))
            }
            groupID += 1
        }
        progress.store(1000, ordering: .relaxed)
        var result = CategoryResult(category: .duplicates, items: items, reclaimable: reclaimable)
        result.groupGains = gains
        return result
    }

    static func edgeHash(_ path: String, size: Int64) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = 65_536
        var buffer = [UInt8](repeating: 0, count: chunk)
        var hasher = SHA256()
        let first = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, 0) }
        guard first >= 0 else { return nil }
        hasher.update(data: buffer[0..<first])
        if size > Int64(chunk) {
            let offset = max(Int64(chunk), size - Int64(chunk))
            let last = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off_t(offset)) }
            guard last >= 0 else { return nil }
            hasher.update(data: buffer[0..<last])
        }
        return Data(hasher.finalize())
    }

    static func fullHash(_ path: String, cancelled: borrowing Atomic<Bool>) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        var hasher = SHA256()
        while true {
            if cancelled.load(ordering: .relaxed) { return nil }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
        }
        return Data(hasher.finalize())
    }
}

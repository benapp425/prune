import Foundation
import Testing
@testable import PruneCore

/// Builds a throwaway folder in ~/Library/Caches (inside the home folder, so the Trash rules allow it).
final class Fixture {
    let root: String

    init() throws {
        root = NSHomeDirectory() + "/Library/Caches/prune-tests/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func file(_ rel: String, bytes: Int, random: Bool = true) throws -> String {
        let path = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        if random { data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) } }
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func scan() -> FileTree { Scanner(options: .init(root: root, threads: 4)).run()! }

    func allocated(_ path: String) -> Int64 {
        var st = stat()
        stat(path, &st)
        return Int64(st.st_blocks) * 512
    }
}

@Test func totalsMatchTheFilesOnDisk() throws {
    let fx = try Fixture()
    let a = try fx.file("a.bin", bytes: 3_000_000)
    let b = try fx.file("sub/b.bin", bytes: 200_000)
    let c = try fx.file("sub/deeper/c.txt", bytes: 10)
    let tree = fx.scan()
    #expect(tree.size(tree.root) == fx.allocated(a) + fx.allocated(b) + fx.allocated(c))
    #expect(tree.fileCount(tree.root) == 3)
    #expect(tree.count == 3)  // root, sub, deeper
    #expect(tree.bigFiles.count == 1)
    let sub = try #require(tree.node(at: fx.root + "/sub"))
    #expect(tree.size(sub) == fx.allocated(b) + fx.allocated(c))
    #expect(tree.path(sub) == fx.root + "/sub")
}

@Test func hardLinksCountOnce() throws {
    let fx = try Fixture()
    let a = try fx.file("a.bin", bytes: 2_000_000)
    try FileManager.default.linkItem(atPath: a, toPath: fx.root + "/link.bin")
    let tree = fx.scan()
    #expect(tree.size(tree.root) == fx.allocated(a))
}

@Test func symlinksAreNotFollowed() throws {
    let fx = try Fixture()
    try fx.file("real/big.bin", bytes: 2_000_000)
    try FileManager.default.createSymbolicLink(atPath: fx.root + "/alias", withDestinationPath: fx.root + "/real")
    let tree = fx.scan()
    #expect(tree.node(at: fx.root + "/alias") == nil)
    #expect(tree.size(tree.root) < 2_200_000)
}

@Test func clonesAreNotCountedAsReclaimable() throws {
    let fx = try Fixture()
    let a = try fx.file("a.bin", bytes: 4_000_000)
    let copy = fx.root + "/copy.bin"
    #expect(clonefile(a, copy, 0) == 0)
    let tree = fx.scan()
    #expect(tree.size(tree.root) >= 8_000_000)        // both files report their full size
    #expect(tree.reclaimable(tree.root) < 1_000_000)  // but deleting either frees almost nothing
}

@Test func markersAreRecorded() throws {
    let fx = try Fixture()
    try fx.file("proj/package.json", bytes: 10)
    try fx.file("proj/node_modules/x/index.js", bytes: 10)
    try fx.file("proj/target/CACHEDIR.TAG", bytes: 10)
    try fx.file("proj/.venv/pyvenv.cfg", bytes: 10)
    let tree = fx.scan()
    let proj = try #require(tree.node(at: fx.root + "/proj"))
    #expect(tree.flags(proj).contains(.nodeProject))
    #expect(tree.flags(try #require(tree.node(at: fx.root + "/proj/target"))).contains(.cacheTag))
    #expect(tree.flags(try #require(tree.node(at: fx.root + "/proj/.venv"))).contains(.pyvenv))
}

@Test func removingAFolderUpdatesItsAncestors() throws {
    let fx = try Fixture()
    try fx.file("keep/a.bin", bytes: 1_500_000)
    try fx.file("drop/b.bin", bytes: 2_500_000)
    let tree = fx.scan()
    let before = tree.size(tree.root)
    let drop = try #require(tree.node(at: fx.root + "/drop"))
    let dropSize = tree.size(drop)
    tree.markRemoved(drop)
    #expect(tree.size(tree.root) == before - dropSize)
    #expect(tree.node(at: fx.root + "/drop") == nil)
    #expect(tree.bigFiles.filter { !$0.removed }.count == 1)
    tree.unmarkRemoved(drop)
    #expect(tree.size(tree.root) == before)
}

@Test func cacheRoundTripKeepsEverything() throws {
    let fx = try Fixture()
    try fx.file("a/b/c.bin", bytes: 1_200_000)
    try fx.file("a/d.txt", bytes: 100)
    try fx.file("é ü/名前.bin", bytes: 1_100_000)
    let tree = fx.scan()
    tree.markRemoved(try #require(tree.node(at: fx.root + "/é ü")))
    let url = URL(fileURLWithPath: fx.root + "/../cache-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try ScanCache.save(tree, to: url)
    let loaded = try #require(ScanCache.load(from: url))
    #expect(loaded.count == tree.count)
    #expect(loaded.size(loaded.root) == tree.size(tree.root))
    #expect(loaded.bigFiles.count == 2)
    #expect(loaded.node(at: fx.root + "/a/b") != nil)
    #expect(loaded.node(at: fx.root + "/é ü") == nil)
}

@Test func guardRefusesWhatWouldBreakTheMac() {
    let h = NSHomeDirectory()
    #expect(RemovalGuard.refusal(for: "/") != nil)
    #expect(RemovalGuard.refusal(for: "/System/Library") != nil)
    #expect(RemovalGuard.refusal(for: h) != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Documents") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/Keychains/login.keychain-db") != nil)
    #expect(RemovalGuard.refusal(for: "/Applications/Foo.app/Contents/MacOS/Foo") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/Containers/com.apple.Safari") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/Caches/com.spotify.client") == nil)
    #expect(RemovalGuard.refusal(for: h + "/Downloads/old.dmg") == nil)
    #expect(RemovalGuard.warning(for: h + "/Library/Mobile Documents/com~apple~CloudDocs/x.pdf") != nil)
}

@Test func trashAndRestoreRoundTrip() throws {
    let fx = try Fixture()
    let path = try fx.file("to-trash/file.bin", bytes: 50_000)
    let folder = fx.root + "/to-trash"
    let result = TrashService.moveToTrash([TrashRequest(path: folder, bytes: 50_000, isDirectory: true)])
    #expect(result.failed.isEmpty)
    let entry = try #require(result.moved.first)
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(FileManager.default.fileExists(atPath: entry.trashedPath))
    try TrashService.restore(entry)
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func trashRefusesProtectedPaths() {
    let result = TrashService.moveToTrash([TrashRequest(path: NSHomeDirectory() + "/Documents", bytes: 0, isDirectory: true)])
    #expect(result.moved.isEmpty)
    #expect(result.failed.count == 1)
}

@Test func duplicatesIgnoreClonesAndFindRealCopies() throws {
    // Duplicate search only looks in your own folders, so build this fixture in a temporary folder under home.
    let base = NSHomeDirectory() + "/prune-dup-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: base) }
    var data = Data(count: 2_000_000)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 2_000_000) }
    try data.write(to: URL(fileURLWithPath: base + "/one.bin"))
    try data.write(to: URL(fileURLWithPath: base + "/two.bin"))   // a real copy
    #expect(clonefile(base + "/one.bin", base + "/three.bin", 0) == 0)  // a clone
    var other = data
    other[1_000_000] ^= 0xFF
    try other.write(to: URL(fileURLWithPath: base + "/different.bin"))  // same size and edges, different middle
    let tree = Scanner(options: .init(root: base, threads: 4)).run()!
    let result = try #require(DuplicateFinder().run(tree: tree))
    let ours = result.items.filter { $0.path.hasPrefix(base) }
    #expect(Set(ours.map { ($0.path as NSString).lastPathComponent }) == ["one.bin", "two.bin", "three.bin"])
}

// MARK: Regressions from the safety review

@Test func guardRefusesSensitiveFoldersThemselves() {
    let h = NSHomeDirectory()
    #expect(RemovalGuard.refusal(for: h + "/Library/Keychains") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/Accounts") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/Mobile Documents/com~apple~CloudDocs") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/CloudStorage/GoogleDrive-me@example.com") != nil)
    #expect(RemovalGuard.refusal(for: h + "/Library/Mobile Documents/com~apple~CloudDocs/old.zip") == nil)
}

@Test func removingAnUncountedFileCantGoNegative() throws {
    let fx = try Fixture()
    try fx.file("a/small.txt", bytes: 5_000)
    let tree = fx.scan()
    let dir = try #require(tree.node(at: fx.root + "/a"))
    tree.removeFile(in: dir, named: "new-download.dmg", allocated: 2_000_000_000, privateSize: 2_000_000_000)
    #expect(tree.size(tree.root) >= 0)
    #expect(tree.ownSize(dir) >= 0)
    let url = URL(fileURLWithPath: fx.root + "/../cache-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try ScanCache.save(tree, to: url)
    #expect(try #require(ScanCache.load(from: url)).size(0) >= 0)
}

@Test func puttingBackAFolderKeepsSeparatelyTrashedFilesGone() throws {
    let fx = try Fixture()
    try fx.file("x/big.iso", bytes: 1_500_000)
    try fx.file("x/other.bin", bytes: 1_200_000)
    let tree = fx.scan()
    let x = try #require(tree.node(at: fx.root + "/x"))
    let iso = try #require(tree.bigFiles.first { $0.name == "big.iso" })
    tree.removeFile(in: x, named: "big.iso", allocated: iso.allocated, privateSize: iso.privateSize)
    tree.markRemoved(x)
    tree.unmarkRemoved(x)
    #expect(tree.bigFiles.first { $0.name == "big.iso" }?.removed == true)
    #expect(tree.bigFiles.first { $0.name == "other.bin" }?.removed == false)
}

@Test func putBackRefusesADifferentItemWithTheSameName() throws {
    let fx = try Fixture()
    try fx.file("one/node_modules/a.js", bytes: 100)
    let first = TrashService.moveToTrash([TrashRequest(path: fx.root + "/one/node_modules", bytes: 100, isDirectory: true)])
    var entry = try #require(first.moved.first)
    #expect(entry.stillInTrash)
    // Stand-in for "the Trash was emptied, then something else landed under the same name".
    try FileManager.default.removeItem(atPath: entry.trashedPath)
    try FileManager.default.createDirectory(atPath: entry.trashedPath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: entry.trashedPath) }
    #expect(!entry.stillInTrash)
    #expect(throws: (any Error).self) { try TrashService.restore(entry) }
    entry.inode = nil
    #expect(!entry.stillInTrash)  // entries without an identity are never put back
}

@Test func putBackRefusesWhenTheFolderItCameFromIsGone() throws {
    let fx = try Fixture()
    try fx.file("p/old/assets/logo.png", bytes: 100)
    let child = TrashService.moveToTrash([TrashRequest(path: fx.root + "/p/old/assets", bytes: 100, isDirectory: true)])
    let parent = TrashService.moveToTrash([TrashRequest(path: fx.root + "/p/old", bytes: 0, isDirectory: true)])
    let c = try #require(child.moved.first), p = try #require(parent.moved.first)
    defer { try? FileManager.default.removeItem(atPath: c.trashedPath); try? FileManager.default.removeItem(atPath: p.trashedPath) }
    #expect(throws: (any Error).self) { try TrashService.restore(c) }
    #expect(!FileManager.default.fileExists(atPath: fx.root + "/p/old"))
    try TrashService.restore(p)
    try TrashService.restore(c)
    #expect(FileManager.default.fileExists(atPath: fx.root + "/p/old/assets/logo.png"))
}

@Test func onlyRealVirtualEnvironmentsAndSignedCacheTagsCount() throws {
    let fx = try Fixture()
    try fx.file("proj/.venv/pyvenv.cfg", bytes: 10)
    try fx.file("proj/.venv/bin/python", bytes: 10)
    try fx.file("proj/.venv/lib/site.py", bytes: 10)
    try fx.file("hw3/pyvenv.cfg", bytes: 10)
    try fx.file("hw3/bin/python", bytes: 10)
    try fx.file("hw3/lib/x.py", bytes: 10)
    try fx.file("data/CACHEDIR.TAG", bytes: 10)
    let tree = fx.scan()
    #expect(ClutterEngine.isVirtualEnvironment(try #require(tree.node(at: fx.root + "/proj/.venv")), in: tree))
    #expect(!ClutterEngine.isVirtualEnvironment(try #require(tree.node(at: fx.root + "/hw3")), in: tree))
    #expect(!ClutterEngine.hasCacheDirSignature(fx.root + "/data"))
    try "Signature: 8a477f597d28d172789f06886806bc55\n".write(toFile: fx.root + "/data/CACHEDIR.TAG", atomically: true, encoding: .utf8)
    #expect(ClutterEngine.hasCacheDirSignature(fx.root + "/data"))
}

import Foundation

/// One item Prune moved to the Trash, so it can be put back.
public struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var originalPath: String
    public var trashedPath: String
    public var bytes: Int64
    public var isDirectory: Bool
    public var date: Date
    public var restored = false
    /// File system identity of the item in the Trash, so Put Back never moves a different item with the same name.
    public var device: Int32? = nil
    public var inode: UInt64? = nil

    public var name: String { (originalPath as NSString).lastPathComponent }

    /// Still in the Trash, and still the same item that was moved there.
    public var stillInTrash: Bool {
        guard !restored, let inode, let device else { return false }
        var st = stat()
        guard lstat(trashedPath, &st) == 0 else { return false }
        return UInt64(st.st_ino) == inode && st.st_dev == device
    }
}

public final class HistoryStore: @unchecked Sendable {
    public private(set) var entries: [HistoryEntry] = []
    private let url: URL

    public init(url: URL = AppPaths.support.appendingPathComponent("history.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    public func add(_ new: [HistoryEntry]) {
        entries.insert(contentsOf: new, at: 0)
        save()
    }

    public func markRestored(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].restored = true
        save()
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(entries) { try? AppPaths.writePrivately(data, to: url) }
    }
}

public struct TrashRequest: Sendable {
    public let path: String
    public let bytes: Int64
    public let isDirectory: Bool
    public init(path: String, bytes: Int64, isDirectory: Bool) {
        self.path = path
        self.bytes = bytes
        self.isDirectory = isDirectory
    }
}

public struct TrashFailure: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let reason: String
}

public enum TrashService {
    /// Moves each item to the Trash. Nothing is deleted outright.
    public static func moveToTrash(_ requests: [TrashRequest]) -> (moved: [HistoryEntry], failed: [TrashFailure]) {
        var moved: [HistoryEntry] = []
        var failed: [TrashFailure] = []
        let fm = FileManager.default
        for r in requests {
            if AppPaths.isDemo {
                failed.append(TrashFailure(path: r.path, reason: "Not available in the demo."))
                continue
            }
            if let reason = RemovalGuard.refusal(for: r.path) ?? RemovalGuard.changeOnDisk(for: r.path, isDirectory: r.isDirectory) {
                failed.append(TrashFailure(path: r.path, reason: reason))
                continue
            }
            var result: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: r.path), resultingItemURL: &result)
                var entry = HistoryEntry(originalPath: r.path, trashedPath: result?.path ?? "", bytes: r.bytes,
                                         isDirectory: r.isDirectory, date: Date())
                var st = stat()
                if let p = result?.path, lstat(p, &st) == 0 {
                    entry.device = st.st_dev
                    entry.inode = UInt64(st.st_ino)
                }
                moved.append(entry)
            } catch {
                failed.append(TrashFailure(path: r.path, reason: friendly(error)))
            }
        }
        return (moved, failed)
    }

    /// Moves an item back from the Trash to where it was.
    public static func restore(_ entry: HistoryEntry) throws {
        let fm = FileManager.default
        guard !AppPaths.isDemo else { throw RestoreError("Not available in the demo.") }
        // History is a file other programs could edit, so only move items out of the Trash,
        // and only to places Prune could have moved them from.
        let trash = AppPaths.home + "/.Trash"
        guard entry.stillInTrash, RemovalGuard.isPlain(entry.trashedPath),
              (entry.trashedPath as NSString).deletingLastPathComponent == trash,
              RemovalGuard.realPath(trash) == trash else {
            throw RestoreError("The item is no longer in the Trash.")
        }
        guard RemovalGuard.refusal(for: entry.originalPath) == nil else {
            throw RestoreError("Items can't be put back in that location.")
        }
        guard !fm.fileExists(atPath: entry.originalPath) else {
            throw RestoreError("An item with the same name already exists in that location.")
        }
        let parent = (entry.originalPath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
            throw RestoreError("The folder it was in is gone. Put back that folder first, or drag the item out of the Trash in Finder.")
        }
        guard RemovalGuard.realPath(parent) == parent else {
            throw RestoreError("The folder it was in has moved. Drag the item out of the Trash in Finder.")
        }
        // RENAME_EXCL fails instead of replacing anything that appeared there in the meantime.
        guard renamex_np(entry.trashedPath, entry.originalPath, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw RestoreError("An item with the same name already exists in that location.") }
            throw RestoreError(String(cString: strerror(errno)))
        }
    }

    public struct RestoreError: LocalizedError {
        public let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
        if ns.code == NSFileWriteNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
            return "You don't have permission to move it."
        }
        if ns.code == NSFileNoSuchFileError { return "The item can't be found." }
        return ns.localizedDescription
    }

    /// Size of the Trash, or nil when macOS doesn't let Prune look inside it.
    public static func trashSize() -> Int64? {
        let path = AppPaths.home + "/.Trash"
        var total: Int64 = 0
        var readable = false
        let lister = BulkLister()
        var stack = [path]
        while let dir = stack.popLast() {
            let err = lister.list(dir) { e in
                if e.kind == .directory && !e.isDataless { stack.append(dir + "/" + e.name) } else { total += e.allocated }
            }
            if dir == path {
                if err != 0 { return nil }
                readable = true
            }
        }
        return readable ? total : nil
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

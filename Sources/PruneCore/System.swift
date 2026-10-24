import Foundation

// MARK: Formatting

public enum Bytes {
    public static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "Zero KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "55.2" and "GB", for a big number with a small unit beside it.
    public static func parts(_ bytes: Int64) -> (number: String, unit: String) {
        let s = format(bytes)
        guard let space = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}

// MARK: Removal rules

/// Decides what may be moved to the Trash. The app refuses anything that would break macOS,
/// your user account or an app, whatever the user picks.
public enum RemovalGuard {
    private static var home: String { AppPaths.home }
    private static let required = "Required by macOS or your user account."
    private static let cloudRoot = "The top folder of a cloud drive. Select items inside it instead."

    // Compared in lowercase, because the startup disk ignores case: ~/library/keychains is the Keychains folder.
    private static var protectedExact: Set<String> {
        let h = home.lowercased()
        let inHome = ["", "/Library", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music", "/Pictures",
                      "/Public", "/Applications", "/Library/Application Support", "/Library/Caches",
                      "/Library/Containers", "/Library/Group Containers", "/Library/Preferences",
                      "/Library/Mobile Documents", "/Library/CloudStorage", "/Library/Mail", "/Library/Messages",
                      "/Library/Developer", "/Library/Logs", "/Library/Application Support/MobileSync",
                      "/Library/Application Support/MobileSync/Backup", "/.Trash", "/.ssh", "/.config"]
        return Set(inHome.map { h + $0.lowercased() }).union(["/", "/applications", "/users", "/users/shared"])
    }

    private static var protectedTrees: [String] {
        let h = home.lowercased()
        return ["/library/keychains", "/.trash", "/.ssh", "/library/preferences", "/library/accounts", "/library/mail",
                "/library/messages"].map { h + $0 }
    }

    /// Why the item can't be removed, or nil if it can.
    public static func refusal(for path: String) -> String? {
        // One spelling per item, so a protected folder can't get through as ~/Documents/ or ~/Library/../Library.
        guard isPlain(path) else { return "Not a valid location." }
        let p = path.lowercased()
        let h = home.lowercased()
        if protectedExact.contains(p) { return required }
        for tree in protectedTrees where p == tree || p.hasPrefix(tree + "/") { return required }
        // The roots of iCloud Drive and cloud storage providers: removing one empties that drive everywhere.
        // Google Drive keeps each drive a level further down, in GoogleDrive-<account>/My Drive.
        let parent = (p as NSString).deletingLastPathComponent
        let cloudStorage = h + "/library/cloudstorage"
        if parent == h + "/library/mobile documents" || parent == cloudStorage { return cloudRoot }
        if (parent as NSString).deletingLastPathComponent == cloudStorage,
           (parent as NSString).lastPathComponent.hasPrefix("googledrive-") { return cloudRoot }
        let allowed = p.hasPrefix(h + "/") || p.hasPrefix("/users/shared/") || p.hasPrefix("/applications/")
        if !allowed { return "Managed by macOS." }
        if p.hasPrefix(h + "/library/containers/com.apple.") || p.hasPrefix(h + "/library/group containers/group.com.apple.") {
            return "Belongs to an Apple app."
        }
        if insidePackage(path) { return "Part of an app or package. Select the whole item instead." }
        if p.hasPrefix("/applications/"), p.hasSuffix(".app") {
            if let id = Bundle(path: path)?.bundleIdentifier, id.hasPrefix("com.apple.") { return "Included with macOS." }
        }
        return nil
    }

    /// An absolute path with no empty, "." or ".." parts and no trailing slash.
    public static func isPlain(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path == "/" { return true }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Checks the item on disk right before it moves: it must still be a folder or a file as the scan saw it,
    /// spelled the way the disk spells it, with no symbolic link in the folders above it to redirect the move.
    /// Returns why it can't be moved, or nil.
    public static func changeOnDisk(for path: String, isDirectory: Bool) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "The item can't be found." }
        let changed = "Changed since the last scan. Scan again."
        let parent = (path as NSString).deletingLastPathComponent
        guard realPath(parent) == parent else { return changed }
        let type = st.st_mode & S_IFMT
        if type != S_IFLNK && realPath(path) != path { return changed }
        if isDirectory && type != S_IFDIR { return changed }
        if !isDirectory && type == S_IFDIR && !Scanner.packageExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return changed
        }
        return nil
    }

    /// The path with symbolic links resolved and each name spelled as it is on disk.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Something worth knowing before removing the item, or nil.
    public static func warning(for path: String) -> String? {
        let h = home
        if path.hasPrefix(h + "/Library/Mobile Documents/") { return "Also removes it from iCloud on all your devices." }
        if path.hasPrefix(h + "/Library/CloudStorage/") { return "Also removes it from the cloud service." }
        if path.hasPrefix(h + "/Desktop/") || path.hasPrefix(h + "/Documents/") {
            if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                return "Also removes it from iCloud on all your devices."
            }
        }
        if path.hasSuffix(".app") { return "Uninstalls the app." }
        if path.hasSuffix(".photoslibrary") { return "Removes an entire Photos library." }
        if (path as NSString).lastPathComponent == ".git" { return "Removes the project's version history." }
        return nil
    }

    static func insidePackage(_ path: String) -> Bool {
        let parts = path.split(separator: "/").dropLast()
        for part in parts {
            let lower = part.lowercased()
            guard let dot = lower.lastIndex(of: ".") else { continue }
            if Scanner.packageExtensions.contains(String(lower[lower.index(after: dot)...])) { return true }
        }
        return false
    }
}

// MARK: Disk

public struct VolumeInfo: Sendable, Equatable {
    public var name: String
    public var total: Int64
    public var available: Int64
    /// Free space plus what macOS can purge on its own.
    public var availableWithPurgeable: Int64

    /// Space in use that macOS can't reclaim on its own.
    public var used: Int64 { max(0, total - availableWithPurgeable) }
    /// Space macOS frees by itself when needed: local snapshots holding deleted files, iCloud copies, some caches.
    /// Finder and System Settings count it as available.
    public var purgeable: Int64 { max(0, availableWithPurgeable - available) }

    public static func current(path: String = "/") -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
        let available = Int64(v?.volumeAvailableCapacity ?? 0)
        return VolumeInfo(name: v?.volumeName ?? "Macintosh HD", total: Int64(v?.volumeTotalCapacity ?? 0),
                          available: available,
                          availableWithPurgeable: max(available, v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

public enum TimeMachine {
    public struct ThinError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Removes local Time Machine snapshots on the startup disk so the space they hold is freed now.
    /// Backups on other disks aren't touched. Asks for an administrator password if macOS requires one.
    public static func removeLocalSnapshots() throws {
        let command = "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["thinlocalsnapshots", "/", "999999999999", "4"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 && localSnapshotCount() == 0 { return }
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw ThinError(message: "Cancelled.") }
            throw ThinError(message: error[NSAppleScript.errorMessage] as? String ?? "Snapshots couldn't be removed.")
        }
    }

    /// Number of local Time Machine snapshots on the startup disk. Snapshots macOS takes for updates aren't counted:
    /// tmutil can't remove them.
    public static func localSnapshotCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("com.apple.TimeMachine.") }.count
    }
}

public enum Permissions {
    /// Whether this app can read folders macOS privacy protection guards (Mail, Messages, Safari).
    public static func hasFullDiskAccess() -> Bool {
        let h = AppPaths.home
        let probes = [h + "/Library/Safari", h + "/Library/Mail", h + "/Library/Messages",
                      "/Library/Application Support/com.apple.TCC"]
        var any = false
        for path in probes {
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd < 0 {
                if errno == EPERM || errno == EACCES { return false }
                continue
            }
            close(fd)
            any = true
        }
        return any
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
}

// MARK: What fills the disk

public enum UsageKind: String, CaseIterable, Sendable {
    case apps = "Applications"
    case documents = "Documents"
    case media = "Movies, Music and Pictures"
    case downloads = "Downloads"
    case appData = "App Data"
    case developer = "Developer"
    case system = "macOS"
    case other = "Other"
}

public struct UsageSlice: Sendable, Identifiable {
    public let kind: UsageKind
    public let bytes: Int64
    public var id: UsageKind { kind }
}

public enum UsageBreakdown {
    public static func compute(_ tree: FileTree) -> [UsageSlice] {
        let h = AppPaths.home
        var totals: [UsageKind: Int64] = [:]
        func add(_ path: String, _ kind: UsageKind) -> Int64 {
            guard let n = tree.node(at: path) else { return 0 }
            let b = tree.size(n)
            totals[kind, default: 0] += b
            return b
        }
        var homeCounted: Int64 = 0
        homeCounted += add(h + "/Applications", .apps)
        homeCounted += add(h + "/Desktop", .documents)
        homeCounted += add(h + "/Documents", .documents)
        homeCounted += add(h + "/Library/Mobile Documents", .documents)
        homeCounted += add(h + "/Movies", .media)
        homeCounted += add(h + "/Music", .media)
        homeCounted += add(h + "/Pictures", .media)
        homeCounted += add(h + "/Downloads", .downloads)
        var library: Int64 = 0
        if let lib = tree.node(at: h + "/Library") {
            library = tree.size(lib)
            let dev = tree.node(at: h + "/Library/Developer").map { tree.size($0) } ?? 0
            let docs = tree.node(at: h + "/Library/Mobile Documents").map { tree.size($0) } ?? 0
            totals[.developer, default: 0] += dev
            totals[.appData, default: 0] += max(0, library - dev - docs)
            homeCounted += library - docs
        }
        if let homeNode = tree.node(at: h) {
            // Hidden folders in your home folder (.npm, .cache, .cargo…) are almost always developer tools.
            var dot: Int64 = 0
            for c in tree.liveChildren(homeNode) where tree.name(c).hasPrefix(".") && tree.name(c) != ".Trash" {
                dot += tree.size(c)
            }
            totals[.developer, default: 0] += dot
            totals[.other, default: 0] += max(0, tree.size(homeNode) - homeCounted - dot)
        }
        if tree.rootPath == "/" {
            _ = add("/Applications", .apps)
            for p in ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores"] { _ = add(p, .system) }
            _ = add("/opt", .developer)
            if let users = tree.node(at: "/Users") {
                let others = tree.liveChildren(users).filter { tree.path($0) != h }.reduce(Int64(0)) { $0 + tree.size($1) }
                totals[.other, default: 0] += others
            }
        }
        return UsageKind.allCases.compactMap { k in
            let b = totals[k] ?? 0
            return b > 0 ? UsageSlice(kind: k, bytes: b) : nil
        }
    }
}

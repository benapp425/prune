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
    private static var home: String { NSHomeDirectory() }

    private static var protectedExact: Set<String> {
        let h = home
        let inHome = ["", "/Library", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music", "/Pictures",
                      "/Public", "/Applications", "/Library/Application Support", "/Library/Caches",
                      "/Library/Containers", "/Library/Group Containers", "/Library/Preferences",
                      "/Library/Mobile Documents", "/Library/CloudStorage", "/Library/Mail", "/Library/Messages",
                      "/Library/Developer", "/Library/Logs", "/Library/Application Support/MobileSync",
                      "/Library/Application Support/MobileSync/Backup", "/.Trash", "/.ssh", "/.config"]
        return Set(inHome.map { h + $0 }).union(["/", "/Applications", "/Users", "/Users/Shared"])
    }

    private static var protectedTrees: [String] {
        let h = home
        return [h + "/Library/Keychains", h + "/.Trash", h + "/.ssh", h + "/Library/Preferences",
                h + "/Library/Accounts", h + "/Library/Mail", h + "/Library/Messages"]
    }

    /// Why the item can't be removed, or nil if it can.
    public static func refusal(for path: String) -> String? {
        let h = home
        if protectedExact.contains(path) { return "Needed by macOS or your account." }
        for tree in protectedTrees where path.hasPrefix(tree + "/") { return "Needed by macOS or your account." }
        let allowed = path.hasPrefix(h + "/") || path.hasPrefix("/Users/Shared/") || path.hasPrefix("/Applications/")
        if !allowed { return "Outside your home folder. macOS manages it." }
        if path.hasPrefix(h + "/Library/Containers/com.apple.") || path.hasPrefix(h + "/Library/Group Containers/group.com.apple.") {
            return "Belongs to an Apple app."
        }
        if insidePackage(path) { return "Part of an app or library. Remove the whole thing instead." }
        if path.hasPrefix("/Applications/"), path.hasSuffix(".app") {
            if let id = Bundle(path: path)?.bundleIdentifier, id.hasPrefix("com.apple.") { return "Comes with macOS." }
        }
        return nil
    }

    /// Something worth knowing before removing the item, or nil.
    public static func warning(for path: String) -> String? {
        let h = home
        if path.hasPrefix(h + "/Library/Mobile Documents/") { return "Deletes it from iCloud on all your devices." }
        if path.hasPrefix(h + "/Library/CloudStorage/") { return "Deletes it from the cloud service too." }
        if path.hasPrefix(h + "/Desktop/") || path.hasPrefix(h + "/Documents/") {
            if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                return "Deletes it from iCloud on all your devices."
            }
        }
        if path.hasSuffix(".app") { return "Uninstalls the app." }
        if path.hasSuffix(".photoslibrary") { return "Deletes a Photos library." }
        if (path as NSString).lastPathComponent == ".git" { return "Deletes the project's version history." }
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

    public var used: Int64 { max(0, total - available) }
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
    /// Number of local Time Machine snapshots on the startup disk.
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
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("com.apple") }.count
    }
}

public enum Permissions {
    /// Whether this app can read folders macOS privacy protection guards (Mail, Messages, Safari).
    public static func hasFullDiskAccess() -> Bool {
        let h = NSHomeDirectory()
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
    case apps = "Apps"
    case documents = "Documents"
    case media = "Media"
    case downloads = "Downloads"
    case appData = "App data"
    case developer = "Developer"
    case system = "macOS and system"
    case other = "Other files"
}

public struct UsageSlice: Sendable, Identifiable {
    public let kind: UsageKind
    public let bytes: Int64
    public var id: UsageKind { kind }
}

public enum UsageBreakdown {
    public static func compute(_ tree: FileTree) -> [UsageSlice] {
        let h = NSHomeDirectory()
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

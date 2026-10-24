import AppKit

/// The apps installed on this Mac, for naming cache folders and spotting data left by deleted apps.
public final class AppCatalog: @unchecked Sendable {
    public struct App: Sendable {
        public let name: String
        public let bundleID: String
        public let path: String
    }

    public private(set) var apps: [App] = []
    private var byID: [String: App] = [:]
    private var vendors: Set<String> = []
    private var nameKeys: Set<String> = []

    public init() {
        let fm = FileManager.default
        let home = AppPaths.home
        let roots = ["/Applications", "/Applications/Utilities", home + "/Applications",
                     "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices"]
        var seen = Set<String>()
        func add(_ path: String) {
            guard seen.insert(path).inserted, let bundle = Bundle(path: path) else { return }
            let info = bundle.infoDictionary ?? [:]
            let id = (info["CFBundleIdentifier"] as? String) ?? ""
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let app = App(name: name, bundleID: id, path: path)
            apps.append(app)
            if !id.isEmpty { byID[id.lowercased()] = app }
            vendors.insert(Self.vendor(of: id))
            for key in Self.keys(for: name) + Self.keys(for: ((path as NSString).lastPathComponent as NSString).deletingPathExtension) {
                nameKeys.insert(key)
            }
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = root + "/" + item
                if item.hasSuffix(".app") {
                    add(path)
                } else if !item.hasPrefix("."), let inner = try? fm.contentsOfDirectory(atPath: path) {
                    // Suites such as "Adobe Photoshop 2025/Adobe Photoshop 2025.app".
                    for sub in inner where sub.hasSuffix(".app") { add(path + "/" + sub) }
                }
            }
        }
        vendors.remove("")
    }

    /// Normalized names an app might use for its folders: "Visual Studio Code" gives "visualstudiocode" and "visual".
    static func keys(for name: String) -> [String] {
        let lower = name.lowercased()
        var out = [lower.filter { $0.isLetter || $0.isNumber }]
        if let first = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first, first.count >= 4 {
            out.append(String(first))
        }
        return out.filter { !$0.isEmpty }
    }

    static func vendor(of bundleID: String) -> String {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return "" }
        return parts[0] + "." + parts[1]
    }

    /// True for names like "com.spotify.client".
    public static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, let first = parts.first else { return false }
        return first.count <= 6 && first.allSatisfy { $0.isLetter } && !name.contains(" ")
    }

    public func app(forBundleID id: String) -> App? {
        if let a = byID[id.lowercased()] { return a }
        // Helpers and extensions: "com.spotify.client.helper" belongs to "com.spotify.client".
        var parts = id.lowercased().split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            if let a = byID[parts.joined(separator: ".")] { return a }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let bundle = Bundle(url: url) {
            let name = (bundle.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            return App(name: name, bundleID: id, path: url.path)
        }
        return nil
    }

    public func isInstalled(bundleID id: String) -> Bool { app(forBundleID: id) != nil }

    /// Whether any installed app comes from the same developer ("com.microsoft" for "com.microsoft.teams2").
    public func vendorInstalled(_ id: String) -> Bool { vendors.contains(Self.vendor(of: id)) }

    /// Whether a plain folder name ("Steam", "BraveSoftware") matches an installed app.
    public func matchesInstalledApp(folderName: String) -> Bool {
        let folderKeys = Self.keys(for: folderName)
        guard let full = folderKeys.first else { return true }
        if nameKeys.contains(full) { return true }
        for key in nameKeys where key.count >= 4 {
            if full.contains(key) || (full.count >= 4 && key.contains(full)) { return true }
        }
        return false
    }

    /// A readable name for a folder named after an app: "com.figma.Desktop" becomes "Figma".
    public func displayName(forFolder name: String) -> String {
        guard Self.looksLikeBundleID(name) else { return name }
        if let app = app(forBundleID: name) { return app.name }
        let parts = name.split(separator: ".").map(String.init)
        let generic: Set<String> = ["client", "desktop", "app", "mac", "macos", "osx", "helper", "agent", "main", "electron"]
        var pick = parts.last ?? name
        if generic.contains(pick.lowercased()), parts.count >= 2 { pick = parts[1] }
        return pick.prefix(1).uppercased() + pick.dropFirst()
    }

    public func iconPath(forFolder name: String) -> String? {
        if Self.looksLikeBundleID(name) { return app(forBundleID: name)?.path }
        return nil
    }

    /// Running apps, by lowercase bundle ID and by lowercase name, each mapped to the app's display name.
    public static func running() -> (ids: [String: String], names: [String: String]) {
        var ids: [String: String] = [:], names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let display = app.localizedName ?? app.executableURL?.lastPathComponent ?? ""
            if let id = app.bundleIdentifier { ids[id.lowercased()] = display }
            if let n = app.localizedName { names[n.lowercased()] = display }
            if let exe = app.executableURL?.lastPathComponent { names[exe.lowercased()] = display }
        }
        return (ids, names)
    }
}

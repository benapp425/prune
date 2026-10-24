import Foundation

/// A made-up Mac used for screenshots (PRUNE_DEMO=1 with PRUNE_HOME=/Users/alex), so pictures of Prune
/// never show anyone's real files.
public enum DemoData {
    public static let volume = VolumeInfo(name: "Macintosh HD", total: 994_662_584_320, available: 287_412_000_000,
                                          availableWithPurgeable: 309_118_000_000)

    private struct D {
        var name: String
        var size: Double = 0          // GB in files directly inside
        var files = 0
        var age: Double = 2           // days since last change
        var flags: NodeFlags = []
        var kids: [D] = []
        var big: [F] = []
    }

    private struct F {
        var name: String
        var size: Double              // GB
        var age: Double
        var added: Double? = nil
    }

    private static func gb(_ x: Double) -> Int64 { Int64(x * 1_000_000_000) }

    public static func tree() -> FileTree {
        let user = (AppPaths.home as NSString).lastPathComponent
        let root = D(name: "/", kids: [
            D(name: "Applications", kids: apps),
            D(name: "Library", size: 11.2, files: 41_000, age: 1),
            D(name: "System", size: 15.8, files: 380_000, age: 30),
            D(name: "Users", kids: [
                D(name: "Shared", size: 1.2, files: 300, age: 90),
                D(name: user, size: 0.01, files: 12, age: 0.1, kids: home),
            ]),
            D(name: "opt", kids: [D(name: "homebrew", size: 5.6, files: 60_000, age: 6)]),
            D(name: "private", size: 9.4, files: 52_000, age: 0.1),
            D(name: "usr", size: 2.1, files: 31_000, age: 30),
        ])
        let tree = FileTree(rootPath: "/")
        let now = Date().timeIntervalSince1970
        build(tree, node: tree.root, spec: root, now: now)
        tree.computeTotals()
        tree.scanDate = Date().addingTimeInterval(-60 * 14)
        tree.scanDuration = 41
        return tree
    }

    private static func build(_ tree: FileTree, node: NodeID, spec: D, now: Double) {
        let start = NodeID(tree.count)
        for k in spec.kids {
            var flags = k.flags
            let lower = k.name.lowercased()
            if let dot = lower.lastIndex(of: "."), Scanner.packageExtensions.contains(String(lower[lower.index(after: dot)...])) {
                flags.insert(.package)
            }
            _ = tree.append(parent: node, name: k.name, flags: flags, modified: UInt32(now - k.age * 86_400))
        }
        let i = Int(node)
        tree.childStart[i] = start
        tree.childCount[i] = Int32(spec.kids.count)
        let bigTotal = spec.big.reduce(0) { $0 + $1.size }
        tree.ownAlloc[i] = gb(spec.size + bigTotal)
        tree.ownPrivate[i] = gb(spec.size + bigTotal)
        tree.ownFiles[i] = Int32(spec.files + spec.big.count)
        tree.ownNewest[i] = UInt32(now - spec.age * 86_400)
        for f in spec.big {
            let b = gb(f.size)
            tree.bigFiles.append(BigFile(dir: node, name: f.name, logical: b, allocated: b, privateSize: b,
                                         modified: UInt32(now - f.age * 86_400), accessed: UInt32(now - f.age * 86_400),
                                         added: UInt32(now - (f.added ?? f.age) * 86_400), isDataless: false))
        }
        for (offset, k) in spec.kids.enumerated() {
            build(tree, node: start + NodeID(offset), spec: k, now: now)
        }
    }

    private static func app(_ name: String, _ size: Double, age: Double = 20) -> D {
        D(name: name + ".app", size: size, files: Int(size * 9_000), age: age)
    }

    private static let apps: [D] = [
        app("Xcode", 13.8), app("Final Cut Pro", 6.4), app("Logic Pro", 3.9),
        D(name: "Adobe Photoshop 2026", kids: [app("Adobe Photoshop 2026", 5.2)]),
        D(name: "Adobe Premiere Pro 2026", kids: [app("Adobe Premiere Pro 2026", 8.6)]),
        app("Microsoft Word", 2.4), app("Microsoft Excel", 2.3), app("Microsoft PowerPoint", 2.1),
        app("Docker", 2.2), app("Google Chrome", 1.4), app("Slack", 0.6), app("Spotify", 0.5), app("Figma", 0.6),
        app("zoom.us", 0.4), app("Notion", 0.6), app("Visual Studio Code", 0.7), app("Blender", 1.9),
    ]

    private static let home: [D] = [
        D(name: "Desktop", size: 0.4, files: 60, age: 0.5, kids: [
            D(name: "Screenshots", size: 2.3, files: 840, age: 1),
            D(name: "Invoices", size: 0.2, files: 120, age: 12),
        ], big: [F(name: "Brand Assets.zip", size: 1.24, age: 34)]),
        D(name: "Documents", size: 1.1, files: 900, age: 1, kids: [
            D(name: "Client Work", size: 9.2, files: 4_100, age: 3),
            D(name: "Thesis", size: 4.1, files: 600, age: 40, big: [F(name: "Thesis Final.pdf", size: 0.048, age: 40)]),
            D(name: "Archive 2021", size: 14.2, files: 22_000, age: 1_050),
            D(name: "Scans", size: 1.1, files: 380, age: 70),
            D(name: "Taxes", size: 0.4, files: 90, age: 190),
        ]),
        D(name: "Downloads", size: 1.3, files: 412, age: 0.3, kids: [
            D(name: "Lecture Recordings", size: 3.6, files: 24, age: 160),
            D(name: "design-system-v2", size: 0.9, files: 2_300, age: 120),
            D(name: "Rectangle.app", size: 0.03, files: 120, age: 220),
        ], big: [
            F(name: "Unreal Engine 5.4.zip", size: 9.6, age: 300),
            F(name: "Xcode_16.4.xip", size: 7.9, age: 100),
            F(name: "conference-recording.mp4", size: 2.8, age: 180),
            F(name: "dataset-raw-2025.csv", size: 1.4, age: 240),
            F(name: "Brand Assets.zip", size: 1.24, age: 33),
            F(name: "Untitled.crdownload", size: 0.9, age: 9),
            F(name: "Docker.dmg", size: 0.62, age: 45),
            F(name: "Blender-4.4-arm64.dmg", size: 0.41, age: 200),
            F(name: "Figma-125.dmg", size: 0.31, age: 61),
            F(name: "googlechrome.dmg", size: 0.23, age: 88),
            F(name: "Zoom.pkg", size: 0.08, age: 150),
            F(name: "node-v22.12.0.pkg", size: 0.08, age: 75),
            F(name: "Thesis Final.pdf", size: 0.048, age: 39),
            F(name: "Q3 Report.pdf", size: 0.022, age: 7),
        ]),
        D(name: "Movies", size: 0.1, files: 10, age: 20, kids: [
            D(name: "Final Cut Projects", age: 400, kids: [D(name: "Iceland Trip.fcpbundle", size: 38.4, files: 3_100, age: 400)]),
            D(name: "Drone Footage", size: 18.1, files: 240, age: 760),
            D(name: "TV", kids: [D(name: "Media.localized", kids: [D(name: "TV Shows", kids: [D(name: "Severance", kids: [
                D(name: "Season 2", kids: [
                    D(name: "Hello, Ms. Cobel.movpkg", size: 1.6, files: 900, age: 210),
                    D(name: "Goodbye, Mrs. Selvig.movpkg", size: 1.5, files: 880, age: 210),
                ]),
            ])])])]),
        ], big: [F(name: "Wedding Edit Final.mov", size: 4.4, age: 330), F(name: "Iceland Teaser.mov", size: 1.2, age: 395)]),
        D(name: "Music", kids: [D(name: "Music", size: 22.3, files: 4_800, age: 15)]),
        D(name: "Pictures", size: 0.6, files: 200, age: 30, kids: [
            D(name: "Photos Library.photoslibrary", size: 128.4, files: 96_000, age: 0.4),
        ], big: [F(name: "Iceland Teaser.mov", size: 1.2, age: 394)]),
        D(name: "code", age: 5, kids: [
            D(name: "web-dashboard", size: 0.2, files: 340, age: 140, flags: [.nodeProject, .gitRepo], kids: [
                D(name: "node_modules", size: 1.6, files: 48_000, age: 140),
                D(name: ".next", size: 0.5, files: 2_100, age: 140),
                D(name: "src", size: 0.01, files: 210, age: 140),
            ]),
            D(name: "mobile-app", size: 0.3, files: 420, age: 5, flags: [.nodeProject, .gitRepo], kids: [
                D(name: "node_modules", size: 1.1, files: 39_000, age: 5),
            ]),
            D(name: "ml-pipeline", size: 0.4, files: 180, age: 200, flags: [.gitRepo], kids: [
                D(name: ".venv", size: 0.01, files: 3, age: 200, flags: [.pyvenv], kids: [
                    D(name: "bin", size: 0.05, files: 40, age: 200),
                    D(name: "lib", size: 3.35, files: 31_000, age: 200),
                ]),
            ]),
            D(name: "rust-cli", size: 0.05, files: 90, age: 90, flags: [.cargoProject, .gitRepo], kids: [
                D(name: "target", size: 4.8, files: 9_400, age: 90, flags: [.cacheTag]),
            ]),
            D(name: "api", size: 0.1, files: 260, age: 70, flags: [.nodeProject, .gitRepo], kids: [
                D(name: "node_modules", size: 0.7, files: 21_000, age: 70),
            ]),
        ]),
        D(name: ".npm", kids: [D(name: "_cacache", size: 3.9, files: 31_000, age: 4), D(name: "_npx", size: 0.2, files: 4_000, age: 30)]),
        D(name: ".cache", kids: [
            D(name: "huggingface", size: 7.6, files: 140, age: 60),
            D(name: "puppeteer", size: 0.6, files: 900, age: 110),
            D(name: "prisma", size: 0.1, files: 20, age: 70),
        ]),
        D(name: ".cargo", size: 0.4, files: 30, age: 90, kids: [D(name: "registry", size: 1.8, files: 52_000, age: 90)]),
        D(name: ".gradle", kids: [D(name: "caches", size: 1.3, files: 9_000, age: 150)]),
        D(name: ".vscode", size: 0.9, files: 12_000, age: 10),
        D(name: "Library", size: 0.1, files: 40, age: 0.1, kids: library),
    ]

    private static let library: [D] = [
        D(name: "Caches", size: 0.3, files: 900, age: 0.1, kids: [
            D(name: "com.spotify.client", size: 4.2, files: 3_200, age: 0.2),
            D(name: "Google", size: 3.1, files: 9_000, age: 0.1),
            D(name: "JetBrains", size: 2.2, files: 14_000, age: 9),
            D(name: "Homebrew", size: 1.6, files: 140, age: 6),
            D(name: "com.adobe.Photoshop", size: 1.4, files: 600, age: 8),
            D(name: "com.tinyspeck.slackmacgap", size: 1.2, files: 4_000, age: 0.1),
            D(name: "pip", size: 1.0, files: 2_200, age: 30),
            D(name: "Yarn", size: 0.9, files: 11_000, age: 70),
            D(name: "com.figma.Desktop", size: 0.8, files: 1_900, age: 1),
            D(name: "com.microsoft.VSCode.ShipIt", size: 0.6, files: 40, age: 12),
            D(name: "com.apple.Safari", size: 0.5, files: 2_000, age: 0.2),
            D(name: "com.apple.Music", size: 0.4, files: 600, age: 2),
        ]),
        D(name: "Application Support", size: 0.2, files: 300, age: 0.1, kids: [
            D(name: "Steam", size: 34.2, files: 41_000, age: 25),
            D(name: "Adobe", size: 6.1, files: 18_000, age: 8),
            D(name: "Google", kids: [D(name: "Chrome", size: 3.9, files: 22_000, age: 0.1, kids: [
                D(name: "component_crx_cache", size: 0.3, files: 40, age: 3),
            ])]),
            D(name: "Code", size: 1.1, files: 3_000, age: 1, kids: [
                D(name: "CachedExtensionVSIXs", size: 0.6, files: 30, age: 12),
                D(name: "CachedData", size: 0.5, files: 900, age: 1),
                D(name: "Cache", size: 0.4, files: 1_200, age: 1),
            ]),
            D(name: "discord", size: 0.8, files: 1_000, age: 2, kids: [D(name: "Cache", size: 1.1, files: 4_000, age: 2)]),
            D(name: "Slack", size: 0.8, files: 900, age: 0.1, kids: [
                D(name: "Cache", size: 0.7, files: 3_000, age: 0.1),
                D(name: "Code Cache", size: 0.3, files: 800, age: 0.1),
            ]),
            D(name: "MobileSync", kids: [D(name: "Backup", kids: [
                D(name: "00008110-001A2B3C4D5E", size: 16.2, files: 21_000, age: 12),
                D(name: "00008030-00F1E2D3C4B5", size: 9.1, files: 14_000, age: 420),
            ])]),
            D(name: "com.parallels.desktop.console", size: 1.4, files: 600, age: 300),
            D(name: "Sketch", size: 2.1, files: 1_400, age: 410),
            D(name: "Postman", size: 0.6, files: 900, age: 260),
        ]),
        D(name: "Containers", kids: [
            D(name: "com.microsoft.teams2", kids: [D(name: "Data", kids: [D(name: "Library", kids: [
                D(name: "Caches", size: 1.6, files: 5_000, age: 4),
            ])])]),
            D(name: "com.docker.docker", kids: [D(name: "Data", kids: [D(name: "vms", kids: [D(name: "0", kids: [
                D(name: "data", big: [F(name: "Docker.raw", size: 32.0, age: 3)]),
            ])])])]),
            D(name: "com.bohemiancoding.sketch3", size: 1.1, files: 400, age: 400),
            D(name: "com.apple.mail", size: 0.6, files: 900, age: 0.1),
        ]),
        D(name: "Group Containers", size: 3.0, files: 6_000, age: 1),
        D(name: "Developer", kids: [
            D(name: "Xcode", kids: [
                D(name: "DerivedData", size: 9.4, files: 120_000, age: 20),
                D(name: "iOS DeviceSupport", size: 7.1, files: 5_000, age: 60),
                D(name: "Archives", size: 2.6, files: 900, age: 140),
            ]),
            D(name: "CoreSimulator", kids: [
                D(name: "Devices", size: 11.2, files: 90_000, age: 20),
                D(name: "Caches", size: 0.8, files: 2_000, age: 20),
            ]),
        ]),
        D(name: "Logs", size: 0.9, files: 1_400, age: 0.1),
        D(name: "Mobile Documents", size: 6.2, files: 9_000, age: 0.5),
        D(name: "Mail", size: 4.8, files: 60_000, age: 0.1),
        D(name: "Messages", size: 7.4, files: 12_000, age: 0.1),
    ]

    /// Duplicate groups for the demo: big files sharing a name and size in your own folders.
    public static func duplicates(_ tree: FileTree) -> CategoryResult {
        var groups: [String: [BigFile]] = [:]
        for f in tree.bigFiles where !f.removed {
            let path = tree.bigFilePath(f)
            guard path.hasPrefix(AppPaths.home + "/"), !path.contains("/Library/") else { continue }
            groups["\(f.name)|\(f.logical)", default: []].append(f)
        }
        var items: [CleanupItem] = []
        var gains: [Int: Int64] = [:]
        var total: Int64 = 0
        for (g, set) in groups.values.filter({ $0.count > 1 }).sorted(by: { $0[0].logical > $1[0].logical }).enumerated() {
            let sorted = set.sorted { $0.modified < $1.modified }
            let gain = sorted.dropFirst().reduce(Int64(0)) { $0 + $1.privateSize }
            gains[g] = gain
            total += gain
            let section = "\(sorted[0].name) — \(sorted.count) copies, \(Bytes.format(sorted[0].logical)) each"
            for f in sorted {
                items.append(CleanupItem(path: tree.bigFilePath(f), title: f.name,
                                         detail: AppPaths.abbreviate(tree.path(f.dir)), bytes: f.privateSize,
                                         confidence: .safe, date: Date(timeIntervalSince1970: TimeInterval(f.modified)),
                                         dateLabel: "Modified", isDirectory: false, recommended: false,
                                         section: section, group: g))
            }
        }
        var result = CategoryResult(category: .duplicates, items: items, reclaimable: total)
        result.groupGains = gains
        return result
    }
}

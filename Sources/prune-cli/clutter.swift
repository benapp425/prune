import Foundation
import PruneCore

/// prune-cli clutter <path>: scan, then print what each cleanup rule finds.
func runClutter(_ root: String, top: Int) {
    let scanner = Scanner(options: .init(root: root))
    guard let tree = scanner.run() else { return }
    print("scanned \(tree.count) folders in \(String(format: "%.1f", tree.scanDuration)) s")
    let t0 = Date()
    let catalog = AppCatalog()
    print("apps found: \(catalog.apps.count)")
    let results = ClutterEngine(tree: tree, catalog: catalog, settings: CleanupSettings()).analyze()
    print("rules took \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    let t1 = Date()
    let dups = DuplicateFinder().run(tree: tree)!
    print("duplicates took \(String(format: "%.2f", Date().timeIntervalSince(t1))) s")
    for cat in CleanupCategory.allCases {
        let r = cat == .duplicates ? dups : results[cat]!
        print("\n== \(cat.title): \(Bytes.format(r.reclaimable)) in \(r.items.count) items, recommended \(Bytes.format(r.recommendedBytes))")
        for section in r.sections {
            let items = r.items(in: section)
            print("  -- \(section) (\(items.count))")
            for i in items.prefix(top) {
                print("     \(i.recommended ? "[x]" : "[ ]") \(Bytes.format(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(i.title) — \(i.detail)\(i.note.map { " · " + $0 } ?? "")")
            }
        }
    }
    let slices = UsageBreakdown.compute(tree)
    print("\n== Usage")
    for s in slices { print("  \(s.kind.rawValue): \(Bytes.format(s.bytes))") }
    let v = VolumeInfo.current()
    print("volume \(v.name): total \(Bytes.format(v.total)) free \(Bytes.format(v.available)) purgeable \(Bytes.format(v.purgeable))")
    print("snapshots \(TimeMachine.localSnapshotCount()), full disk access \(Permissions.hasFullDiskAccess()), trash \(TrashService.trashSize().map(Bytes.format) ?? "unreadable")")
    let t2 = Date()
    try? ScanCache.save(tree, to: URL(fileURLWithPath: NSTemporaryDirectory() + "prune-test.bin"))
    let loaded = ScanCache.load(from: URL(fileURLWithPath: NSTemporaryDirectory() + "prune-test.bin"))
    print("cache round trip \(String(format: "%.2f", Date().timeIntervalSince(t2))) s, sizes match: \(loaded?.size(0) == tree.size(0)), count \(loaded?.count ?? -1)")
}

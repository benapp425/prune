import Foundation
import PruneCore

// Command-line front end for checking the scanner against `du` and timing it.
// Usage: prune-cli scan <path> [--no-private] [--threads N] [--top N]

func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "probe" { probe(args[1]); exit(0) }
if args.first == "clutter" { runClutter(URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().path, top: Int(args.count > 2 ? args[2] : "8") ?? 8); exit(0) }
guard args.first == "scan", args.count >= 2 else {
    print("usage: prune-cli scan <path> [--no-private] [--threads N] [--top N] [--save]")
    exit(2)
}
let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().path
var privateSizes = true
var threads = 0
var top = 12
var save = false
var i = 2
while i < args.count {
    switch args[i] {
    case "--no-private": privateSizes = false
    case "--threads": i += 1; threads = Int(args[i]) ?? 0
    case "--top": i += 1; top = Int(args[i]) ?? 12
    case "--save": save = true
    default: break
    }
    i += 1
}

let scanner = Scanner(options: .init(root: root, threads: threads, privateSizes: privateSizes))
let tree = scanner.run()!
if save { try ScanCache.save(tree); print("saved to \(ScanCache.defaultURL.path)") }
let r = tree.root
print("root        \(root)")
print("time        \(String(format: "%.1f", tree.scanDuration)) s on \(scanner.options.threads) threads")
print("folders     \(tree.count)")
print("files       \(tree.fileCount(r))")
print("big files   \(tree.bigFiles.count)")
print("allocated   \(tree.size(r)) (\(fmt(tree.size(r))))")
print("reclaimable \(tree.reclaimable(r)) (\(fmt(tree.reclaimable(r))))")
print("in cloud    \(fmt(tree.cloudBytes(r)))")
var blocked = 0, mounts = 0, cloud = 0
for n in 0..<NodeID(tree.count) {
    let f = tree.flags(n)
    if f.contains(.protected) || f.contains(.unreadable) { blocked += 1 }
    if f.contains(.mountPoint) { mounts += 1 }
    if f.contains(.cloudOnly) { cloud += 1 }
}
print("blocked     \(blocked) folders, mount points \(mounts), cloud-only folders \(cloud)")
print("")
for c in tree.children(r).sorted(by: { tree.size($0) > tree.size($1) }).prefix(top) {
    print(String(format: "%10@  %@", fmt(tree.size(c)) as NSString, tree.name(c) as NSString))
}

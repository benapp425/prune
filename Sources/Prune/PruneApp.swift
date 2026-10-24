import PruneCore
import SwiftUI

@main
struct PruneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Prune", id: "main") {
            RootView()
                .environment(model)
                .tint(Theme.windowTint)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { SelfTest.apply(to: model) }
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands { PruneCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.windowTint)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { ThemeStore.shared.appearance.apply() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PruneCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.phase == .scanning ? "Stop Scanning" : "Scan") {
                if model.phase == .scanning { model.stopScan() } else { model.startScan() }
            }
            .keyboardShortcut("r")
        }
        CommandMenu("Go") {
            Button("Overview") { model.selection = .overview }.keyboardShortcut("1")
            Button("File Browser") { model.selection = .browse }.keyboardShortcut("2")
            ForEach(Array(CleanupCategory.allCases.enumerated()), id: \.element) { i, c in
                Button(c.title) { model.selection = .category(c) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 3)")))
            }
            Button("History") { model.selection = .history }.keyboardShortcut("y")
            Divider()
            Button("Back") { model.goBack() }.keyboardShortcut("[")
            Button("Forward") { model.goForward() }.keyboardShortcut("]")
            Button("Enclosing Folder") { model.goUp() }.keyboardShortcut(.upArrow)
        }
        CommandGroup(replacing: .help) {
            Button("What's New in Prune") { model.showWhatsNew = true }
            Button("Prune on GitHub") { NSWorkspace.shared.open(Changelog.repositoryURL) }
        }
        CommandMenu("Selection") {
            Button(model.showTray ? "Hide Selection" : "Show Selection") { model.showTray.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Select Recommended") { model.reviewRecommended() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Move to Trash…") { model.confirmingTrash = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.tray.isEmpty)
            Button("Deselect All") { model.clearTray() }.disabled(model.tray.isEmpty)
        }
    }
}

/// Launch hooks for photographing the app from a script: PRUNE_SECTION picks a page,
/// PRUNE_TRAY=1 fills the tray with recommended items, PRUNE_INFO names a file that receives the window number.
@MainActor
enum SelfTest {
    static func apply(to model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let section = env["PRUNE_SECTION"] {
            model.showOnboarding = false
            switch section {
            case "overview": model.selection = .overview
            case "browse": model.selection = .browse
            case "history": model.selection = .history
            case "onboarding": model.showOnboarding = true
            default:
                if let c = CleanupCategory(rawValue: section) { model.selection = .category(c) }
            }
        }
        if env["PRUNE_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if env["PRUNE_LIGHT"] == "1" { NSApp.appearance = NSAppearance(named: .aqua) }
        if let browse = env["PRUNE_BROWSE"] {
            Task { @MainActor in
                for _ in 0..<50 where model.tree == nil { try? await Task.sleep(for: .milliseconds(100)) }
                model.reveal(inBrowse: browse)
            }
        }
        if env["PRUNE_TRAY"] == "1" {
            Task { @MainActor in
                for _ in 0..<100 where model.results.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                let items = CleanupCategory.allCases.flatMap { model.result(for: $0)?.items.filter(\.recommended) ?? [] }
                model.addToTray(Array(items.prefix(12)))
                if env["PRUNE_TRAY_OPEN"] == "1" { model.showTray = true }
            }
        }
        if env["PRUNE_SCAN"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                model.startScan()
            }
        }
        // Moves one path to the Trash through the tray, then puts it back, writing what happened to PRUNE_TRASH_LOG.
        if let target = env["PRUNE_TRASH_TEST"], let log = env["PRUNE_TRASH_LOG"] {
            Task { @MainActor in
                for _ in 0..<100 where model.results.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                var lines: [String] = []
                let before = model.tree.map { $0.size($0.root) } ?? 0
                model.addToTray(TrayItem(path: target, title: (target as NSString).lastPathComponent, bytes: 0, isDirectory: true))
                lines.append("tray \(model.tray.count)")
                model.moveTrayToTrash()
                for _ in 0..<50 where model.working { try? await Task.sleep(for: .milliseconds(100)) }
                let after = model.tree.map { $0.size($0.root) } ?? 0
                lines.append("exists after trash \(FileManager.default.fileExists(atPath: target))")
                lines.append("tree shrank by \(before - after)")
                lines.append("toast \(model.toast?.title ?? "none")")
                lines.append("history \(model.historyEntries.first?.originalPath ?? "none")")
                try? await Task.sleep(for: .seconds(2))
                if let undo = model.toast?.undo, !undo.isEmpty { model.restore(undo) }
                lines.append("exists after undo \(FileManager.default.fileExists(atPath: target))")
                lines.append("tree restored \((model.tree.map { $0.size($0.root) } ?? 0) == before)")
                try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
            }
        }
        if let info = env["PRUNE_INFO"] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    if let size = env["PRUNE_SIZE"]?.split(separator: "x"), size.count == 2,
                       let wd = Double(size[0]), let ht = Double(size[1]) {
                        w.setContentSize(NSSize(width: wd, height: ht))
                        w.center()
                    }
                    try? "\(w.windowNumber)".write(toFile: info, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

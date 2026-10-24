import PruneCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    private var onboardingPage: Int {
        #if PRUNE_HOOKS
        if let page = ProcessInfo.processInfo.environment["PRUNE_PAGE"].flatMap(Int.init) { return page }
        #endif
        return UserDefaults.standard.bool(forKey: Prefs.onboarded) ? 1 : 0
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { bottomBar }
        }
        .inspector(isPresented: $model.showTray) {
            TrayView().inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.confirmingTrash) { ConfirmTrashSheet() }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView(startAt: onboardingPage)
        }
        .sheet(isPresented: $model.showWhatsNew) { WhatsNewView() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSystem()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .scanning:
            ScanningView()
        case .empty:
            EmptyScanView()
        case .ready:
            switch model.selection ?? .overview {
            case .overview: OverviewView()
            case .browse: BrowseView()
            case .history: HistoryView()
            case .category(let c): CategoryView(category: c).id(c)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.tray.isEmpty && !model.showTray && model.phase == .ready {
                TrayBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(.snappy, value: model.tray.isEmpty)
        .animation(.snappy, value: model.showTray)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.selection == .browse && model.phase == .ready {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.browseBack.isEmpty)
                    .help("Back")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(model.browseForward.isEmpty)
                    .help("Forward")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.tree.flatMap { t in model.browseNode.flatMap { t.parent($0) } } == nil)
                    .help("Enclosing Folder")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.phase == .scanning {
                Button { model.stopScan() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop scanning")
            } else {
                Button { model.startScan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .help(model.tree == nil ? "Scan" : "Scan Again")
            }
            Button {
                model.showTray.toggle()
            } label: {
                Label("Selection", systemImage: model.tray.isEmpty ? "checklist" : "checklist.checked")
                    .overlay(alignment: .topTrailing) {
                        if !model.tray.isEmpty {
                            Text("\(model.tray.count)")
                                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: 9, y: -7)
                        }
                    }
            }
            .help(model.showTray ? "Hide Selection" : "Show Selection")
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label("Overview", systemImage: "internaldrive").tag(SidebarItem.overview)
                Label("File Browser", systemImage: "folder").tag(SidebarItem.browse)
            }
            Section("Recommendations") {
                ForEach(CleanupCategory.allCases) { c in
                    HStack {
                        Label(c.title, systemImage: c.symbol)
                        Spacer()
                        if let r = model.result(for: c) {
                            if r.reclaimable > 0 {
                                Text(Bytes.format(r.reclaimable))
                                    .font(Theme.number(10.5))
                                    .foregroundStyle(.secondary)
                            }
                        } else if model.phase == .ready {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag(SidebarItem.category(c))
                }
            }
            Section {
                Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskFooter() }
    }
}

/// Free space at the foot of the sidebar.
private struct DiskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let v = model.volume
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Caps(v.name)
                Spacer()
                Text("\(Int((Double(v.used) / Double(max(1, v.total)) * 100).rounded()))%")
                    .font(Theme.number(10.5)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let used = Double(v.used) / Double(max(1, v.total))
                let tray = min(used, Double(model.trayBytes) / Double(max(1, v.total)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Color.primary.opacity(0.45)).frame(width: geo.size.width * used)
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * tray)
                        .offset(x: geo.size.width * (used - tray))
                }
            }
            .frame(height: 5)
            .animation(.snappy, value: model.trayBytes)
            Text("\(Bytes.format(v.availableWithPurgeable)) available of \(Bytes.format(v.total))")
                .font(Theme.number(11)).foregroundStyle(.secondary)
            if let tree = model.tree, model.phase == .ready {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text("Last scanned \(tree.scanDate.relative)")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

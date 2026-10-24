import PruneCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            CleanupSettingsView().tabItem { Label("Recommendations", systemImage: "checklist") }
            ExclusionsSettings().tabItem { Label("Excluded Folders", systemImage: "eye.slash") }
        }
        .frame(width: 540, height: 380)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.scanRoot) private var scanRoot = "/"
    @AppStorage(Prefs.showHidden) private var showHidden = true

    var body: some View {
        Form {
            Section {
                Picker("Scan", selection: Binding(
                    get: { scanRoot == "/" ? "disk" : scanRoot == AppPaths.home ? "home" : "other" },
                    set: { choice in
                        switch choice {
                        case "disk": scanRoot = "/"
                        case "home": scanRoot = AppPaths.home
                        default: chooseFolder()
                        }
                    })) {
                    Text("Macintosh HD").tag("disk")
                    Text("Home Folder").tag("home")
                    if scanRoot != "/" && scanRoot != AppPaths.home {
                        Text(AppPaths.abbreviate(scanRoot)).tag("other")
                    }
                    Divider()
                    Text("Choose Folder…").tag("choose")
                }
                Toggle("Show hidden files in File Browser", isOn: $showHidden)
            }
            Section("Full Disk Access") {
                HStack {
                    Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                        .foregroundStyle(model.hasFullDiskAccess ? Color(nsColor: .systemGreen) : .secondary)
                    Text(model.hasFullDiskAccess ? "On. Prune can measure every folder."
                         : "Off. Mail, Messages, the Trash and other apps' data aren't included.")
                        .font(.system(size: 12))
                    Spacer()
                    if !model.hasFullDiskAccess {
                        Button("Open System Settings") { model.openPrivacySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshSystem() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { scanRoot = url.path }
    }
}

private struct AppearanceSettings: View {
    @Bindable private var store = ThemeStore.shared

    var body: some View {
        Form {
            Section("Color Scheme") {
                ThemePicker()
                    .padding(.vertical, 6)
            }
            Section {
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CleanupSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.largeMinimumMB) private var largeMinimumMB = 250
    @AppStorage(Prefs.unusedMonths) private var unusedMonths = 6
    @AppStorage(Prefs.staleDays) private var staleDays = 60

    var body: some View {
        Form {
            Section("Large Files") {
                Picker("Files larger than", selection: $largeMinimumMB) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                Picker("Not opened in", selection: $unusedMonths) {
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("2 years").tag(24)
                }
            }
            Section {
                Picker("Recommend removing dependencies after", selection: $staleDays) {
                    Text("1 month without changes").tag(30)
                    Text("2 months without changes").tag(60)
                    Text("6 months without changes").tag(180)
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("node_modules folders and virtual environments in projects you haven't changed in this long are included in Recommended.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: largeMinimumMB) { model.analyze(includeDuplicates: false) }
        .onChange(of: unusedMonths) { model.analyze(includeDuplicates: false) }
        .onChange(of: staleDays) { model.analyze(includeDuplicates: false) }
    }
}

private struct ExclusionsSettings: View {
    @AppStorage(Prefs.excluded) private var excludedData = Data()
    @State private var excluded: [String] = UserDefaults.standard.stringArray(forKey: Prefs.excluded) ?? []
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prune doesn't scan these folders.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            List(excluded, id: \.self, selection: $selection) { path in
                HStack {
                    FileIcon(path: path, isDirectory: true, size: 16)
                    Text(AppPaths.abbreviate(path)).lineLimit(1).truncationMode(.middle)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 0) {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.prompt = "Exclude"
                    if panel.runModal() == .OK {
                        for url in panel.urls where !excluded.contains(url.path) { excluded.append(url.path) }
                        save()
                    }
                } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                Button {
                    excluded.removeAll { $0 == selection }
                    selection = nil
                    save()
                } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                .disabled(selection == nil)
                Spacer()
                Text("Takes effect on the next scan.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(20)
    }

    private func save() { UserDefaults.standard.set(excluded, forKey: Prefs.excluded) }
}

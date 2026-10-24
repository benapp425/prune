import PruneCore
import SwiftUI

/// The selection inspector: everything picked for removal, across every page.
struct TrayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Caps("Selected")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    let p = Bytes.parts(model.trayBytes)
                    Text(p.number).font(.system(size: 30, weight: .light)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(p.unit).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .foregroundStyle(model.tray.isEmpty ? .secondary : Theme.accent)
                Text(model.tray.isEmpty ? "Select items to remove with the checkboxes or the + buttons."
                     : "\(model.tray.count) \(model.tray.count == 1 ? "item" : "items"). Items move to the Trash, so you can put them back.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)

            Divider()

            if model.tray.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No Items Selected").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(model.tray.sorted { $0.bytes > $1.bytes }) { item in
                        TrayRow(item: item)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()
            VStack(spacing: 8) {
                Button {
                    model.confirmingTrash = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .controlSize(.large)
                .prominentButton()
                .tint(Theme.accent)
                .disabled(model.tray.isEmpty || model.working)
                .keyboardShortcut(.delete, modifiers: .command)

                Button("Deselect All") { model.clearTray() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .disabled(model.tray.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 280)
    }
}

private struct TrayRow: View {
    @Environment(AppModel.self) private var model
    let item: TrayItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: item.path, isDirectory: item.isDirectory, iconPath: item.iconPath, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(AppPaths.abbreviate(item.path)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let w = item.warning {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if hover {
                Button {
                    model.removeFromTray(item.path)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Deselect")
            } else {
                SizeText(bytes: item.bytes, font: Theme.number(11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Deselect") { model.removeFromTray(item.path) }
            Button("Show in Finder") { model.revealInFinder(item.path) }
        }
    }
}

/// Floating bar at the bottom of the window whenever something is selected.
struct TrayBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "checklist.checked")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: model.tray.count)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(model.tray.count) \(model.tray.count == 1 ? "item" : "items") selected")
                    .font(.system(size: 12, weight: .semibold))
                Text(Bytes.format(model.trayBytes))
                    .font(Theme.number(11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Divider().frame(height: 22)
            Button("Review") { model.showTray = true }
                .quietButton()
            Button {
                model.confirmingTrash = true
            } label: {
                Label("Move to Trash", systemImage: "trash").font(.system(size: 12.5, weight: .semibold))
            }
            .prominentButton()
            .tint(Theme.accent)
            .disabled(model.working)
        }
        .controlSize(.regular)
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .floatingSurface()
    }
}

/// Confirmation before anything moves.
struct ConfirmTrashSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let warnings = model.tray.filter { $0.warning != nil }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: AppPaths.home + "/.Trash"))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Move \(model.tray.count) \(model.tray.count == 1 ? "item" : "items") to the Trash?")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Empty the Trash to free \(Bytes.format(model.trayBytes)). Until then, you can put items back from History.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings.prefix(5)) { w in
                        Label {
                            Text("\(w.title): \(w.warning ?? "")").font(.system(size: 11.5))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                        }
                    }
                    if warnings.count > 5 {
                        Text("\(warnings.count - 5) more items have warnings.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemOrange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.confirmingTrash = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.moveTrayToTrash()
                } label: {
                    if model.working {
                        ProgressView().controlSize(.small).padding(.horizontal, 22)
                    } else {
                        Text("Move to Trash").padding(.horizontal, 4)
                    }
                }
                .prominentButton()
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.working)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(toast.isError ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 12.5, weight: .semibold))
                if let d = toast.detail {
                    Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if !toast.undo.isEmpty {
                Button("Undo") {
                    model.toast = nil
                    model.restore(toast.undo)
                }
                .quietButton()
                Button("Open Trash") { model.openTrash() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.smooth) { model.toast = nil }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .floatingSurface()
    }
}

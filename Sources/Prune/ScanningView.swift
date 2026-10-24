import PruneCore
import SwiftUI

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            DialView(segments: [], reclaimable: 0, scanning: true, diameter: 290,
                     center: AnyView(VStack(spacing: 2) {
                         let p = Bytes.parts(model.scanBytes)
                         Text(p.number)
                             .font(.system(size: 50, weight: .light))
                             .monospacedDigit()
                             .contentTransition(.numericText())
                         Caps("\(p.unit) Scanned")
                     }))
            HStack(spacing: 34) {
                Counter(label: "Files", value: model.scanFiles.formatted())
                Counter(label: "Folders", value: model.scanFolders.formatted())
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Counter(label: "Elapsed", value: elapsed)
                }
            }
            Text(AppPaths.abbreviate(model.scanPath))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            if model.scanStalled {
                Label {
                    Text(model.hasFullDiskAccess
                         ? "Waiting for a folder to respond…"
                         : "Waiting for permission. Respond to the macOS dialog to continue, or allow Full Disk Access so Prune isn't asked folder by folder.")
                } icon: {
                    Image(systemName: "hand.raised")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .transition(.opacity)
                if !model.hasFullDiskAccess {
                    Button("Open System Settings") { model.openPrivacySettings() }.controlSize(.small)
                }
            }
            Button("Stop") { model.stopScan() }
                .controlSize(.large)
                .quietButton()
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Scanning")
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(model.scanStarted ?? Date()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Counter: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(Theme.number(17)).contentTransition(.numericText())
            Caps(label)
        }
        .frame(minWidth: 90)
    }
}

struct EmptyScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            DialView(segments: [], reclaimable: 0, diameter: 220,
                     center: AnyView(Image(systemName: "magnifyingglass")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)))
            VStack(spacing: 6) {
                Text("Scan Your Mac")
                    .font(.system(size: 22, weight: .semibold))
                Text("Prune measures every folder on your Mac and suggests files you can remove, such as caches, old installers and duplicates. Nothing is removed until you choose, and removed items go to the Trash.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button {
                model.startScan()
            } label: {
                Text(model.scanRoot == "/" ? "Scan \(model.volume.name)" : "Scan \(AppPaths.abbreviate(model.scanRoot))")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .prominentButton()
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

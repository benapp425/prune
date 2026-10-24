import PruneCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSnapshots = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                capacity
                recommended
                tiles
                notes
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .confirmationDialog("Remove local Time Machine snapshots?", isPresented: $confirmSnapshots) {
            Button("Remove Snapshots", role: .destructive) { model.removeSnapshots() }
        } message: {
            Text("macOS keeps hourly snapshots for 24 hours so you can restore recent versions of files. Removing them frees the space they hold now. Backups on your Time Machine disk aren't affected.")
        }
    }

    // MARK: Capacity

    private var capacity: some View {
        let v = model.volume
        let total = Double(max(1, v.total))
        var segments = model.usage.map { DialView.Segment(id: $0.kind.rawValue, fraction: Double($0.bytes) / total, color: Theme.color(for: $0.kind)) }
        if model.unseenBytes > 0 {
            segments.append(.init(id: "unseen", fraction: Double(model.unseenBytes) / total, color: Theme.unseen))
        }
        let available = Bytes.parts(v.availableWithPurgeable)
        return Panel(padding: 26) {
            HStack(alignment: .center, spacing: 40) {
                DialView(segments: segments, reclaimable: Double(model.recommendedBytes) / total, diameter: 260,
                         center: AnyView(VStack(spacing: 2) {
                             Text(available.number)
                                 .font(.system(size: 50, weight: .light))
                                 .monospacedDigit()
                                 .contentTransition(.numericText())
                             Caps("\(available.unit) Available")
                             Text("of \(Bytes.format(v.total))")
                                 .font(.system(size: 11))
                                 .foregroundStyle(.tertiary)
                                 .padding(.top, 4)
                         }))
                    .id("\(model.treeVersion)-\(Theme.current.rawValue)")
                legend
            }
        }
    }

    private var legend: some View {
        let v = model.volume
        let maxBytes = Double(max(1, (model.usage.map(\.bytes) + [model.unseenBytes]).max() ?? 1))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Caps(v.name)
                Spacer()
                Text("\(Bytes.format(v.used)) of \(Bytes.format(v.total)) used")
                    .font(Theme.number(11)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)
            ForEach(model.usage) { slice in
                LegendRow(color: Theme.color(for: slice.kind), title: slice.kind.rawValue, bytes: slice.bytes,
                          fraction: Double(slice.bytes) / maxBytes)
            }
            if model.unseenBytes > 0 {
                LegendRow(color: Theme.unseen, title: "System Data", bytes: model.unseenBytes,
                          fraction: Double(model.unseenBytes) / maxBytes,
                          help: model.hasFullDiskAccess
                            ? "Space used by macOS outside your folders, such as system volumes and file system data."
                            : "Includes folders Prune can't read without Full Disk Access, such as Mail and Messages.")
            }
            Divider().padding(.vertical, 8)
            SummaryRow(marker: AnyView(Circle().fill(Theme.accent).frame(width: 7, height: 7)),
                       title: "Recommended", bytes: model.recommendedBytes, tint: Theme.accent)
            SummaryRow(marker: AnyView(Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)),
                       title: "Purgeable", bytes: v.purgeable, tint: .secondary,
                       help: "Space macOS frees automatically when it's needed, such as local Time Machine snapshots and iCloud files stored on this Mac. Finder counts it as available.")
            SummaryRow(marker: AnyView(Circle().fill(Theme.track).frame(width: 7, height: 7)),
                       title: "Free", bytes: v.available, tint: .secondary)
        }
        .frame(maxWidth: 520)
    }

    // MARK: Recommended

    private var recommended: some View {
        let bytes = model.recommendedBytes
        let parts = Bytes.parts(bytes)
        return Panel(padding: 22) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Caps("Recommended", color: Theme.accent)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(parts.number).font(.system(size: 38, weight: .light)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(parts.unit).font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                    Text(model.analyzing ? "Checking for files you can remove…" :
                            "Caches, old installers and build files that are safe to remove. Another \(Bytes.format(max(0, model.reclaimableBytes - bytes))) is available to review.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button {
                    model.reviewRecommended()
                } label: {
                    Text("Review Files")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .prominentButton()
                .tint(Theme.accent)
                .disabled(bytes == 0)
            }
        }
    }

    // MARK: Categories

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
            ForEach(CleanupCategory.allCases) { c in
                CategoryTile(category: c)
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.hasFullDiskAccess {
                NoteRow(symbol: "lock.shield", title: "Some Folders Weren't Scanned",
                        detail: "Allow Full Disk Access to include Mail, Messages, the Trash and other apps' data.",
                        action: ("Open System Settings", { model.openPrivacySettings() }))
            }
            if model.snapshotCount > 0 {
                NoteRow(symbol: "clock.arrow.circlepath",
                        title: "\(model.snapshotCount) Local Time Machine \(model.snapshotCount == 1 ? "Snapshot" : "Snapshots")",
                        detail: "Snapshots keep deleted files for up to 24 hours, so space you free can show as purgeable instead of free until they expire. macOS removes them automatically when space is needed.",
                        action: (model.removingSnapshots ? "Removing…" : "Remove Snapshots…", { confirmSnapshots = true }))
            }
            if let trash = model.trashSize, trash > 100_000_000 {
                NoteRow(symbol: "trash", title: "\(Bytes.format(trash)) in the Trash",
                        detail: "Empty the Trash to free this space.",
                        action: ("Open Trash", { model.openTrash() }))
            }
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let title: String
    let bytes: Int64
    let fraction: Double
    var help: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 9, height: 9)
            Text(title).font(.system(size: 12.5)).lineLimit(1)
            if help != nil {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Meter(fraction: fraction, tint: color.opacity(0.9), height: 3).frame(width: 64)
            SizeText(bytes: bytes, font: Theme.number(12)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .help(help ?? "")
    }
}

private struct SummaryRow: View {
    let marker: AnyView
    let title: String
    let bytes: Int64
    let tint: Color
    var help: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            marker.frame(width: 9)
            Text(title).font(.system(size: 12.5)).foregroundStyle(tint == .secondary ? .secondary : .primary)
            if help != nil {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            SizeText(bytes: bytes, font: Theme.number(12)).foregroundStyle(tint)
        }
        .padding(.vertical, 3)
        .help(help ?? "")
    }
}

private struct CategoryTile: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    @State private var hover = false

    var body: some View {
        let result = model.result(for: category)
        Button {
            model.selection = .category(category)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: category.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hover ? 1 : 0.5)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title).font(.system(size: 13, weight: .semibold))
                    if let result {
                        Text(Bytes.format(result.reclaimable))
                            .font(.system(size: 22, weight: .light)).monospacedDigit()
                            .foregroundStyle(result.reclaimable > 0 ? .primary : .tertiary)
                            .contentTransition(.numericText())
                        Text(summary(result))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(category == .duplicates && model.duplicateProgress != nil
                                 ? "Comparing Files… \(Int((model.duplicateProgress ?? 0) * 100))%" : "Checking…")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hover ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
    }

    private func summary(_ r: CategoryResult) -> String {
        if r.items.isEmpty { return "Nothing found" }
        let count = category == .duplicates ? Set(r.items.compactMap(\.group)).count : r.items.count
        let noun = category == .duplicates ? (count == 1 ? "file with copies" : "files with copies") : (count == 1 ? "item" : "items")
        let rec = r.recommendedBytes
        return rec > 0 ? "\(count.formatted()) \(noun), \(Bytes.format(rec)) recommended" : "\(count.formatted()) \(noun)"
    }
}

struct NoteRow: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let action {
                Button(action.0, action: action.1).controlSize(.small).quietButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

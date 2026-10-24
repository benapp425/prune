import PruneCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        let groups = grouped(model.historyEntries)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("History").font(.system(size: 24, weight: .semibold))
                        Text("Items moved to the Trash with Prune. You can put them back until the Trash is emptied.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.historyEntries.isEmpty {
                        Button("Clear History…") { confirmClear = true }
                            .controlSize(.small)
                            .quietButton()
                    }
                }
                .padding(.bottom, 10)

                if groups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                        Text("No History").font(.system(size: 15, weight: .medium))
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                }

                ForEach(groups, id: \.day) { group in
                    HStack {
                        Caps(group.day.formatted(date: .complete, time: .omitted))
                        Spacer()
                        SizeText(bytes: group.entries.reduce(0) { $0 + $1.bytes }, font: Theme.number(11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 56) }
                            HistoryRow(entry: entry)
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("History")
        .confirmationDialog("Clear History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Items stay in the Trash. To restore them later, use Put Back in Finder.")
        }
    }

    private func grouped(_ entries: [HistoryEntry]) -> [(day: Date, entries: [HistoryEntry])] {
        let cal = Calendar.current
        var out: [(Date, [HistoryEntry])] = []
        for e in entries {
            let day = cal.startOfDay(for: e.date)
            if let last = out.last, last.0 == day { out[out.count - 1].1.append(e) } else { out.append((day, [e])) }
        }
        return out.map { (day: $0.0, entries: $0.1) }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry

    var body: some View {
        let inTrash = entry.stillInTrash
        HStack(spacing: 12) {
            FileIcon(path: inTrash ? entry.trashedPath : entry.originalPath, isDirectory: entry.isDirectory, size: 28)
                .opacity(inTrash ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(AppPaths.abbreviate((entry.originalPath as NSString).deletingLastPathComponent))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            SizeText(bytes: entry.bytes, font: Theme.number(12.5)).frame(width: 70, alignment: .trailing)
            Group {
                if entry.restored {
                    Text("Restored").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if inTrash {
                    Button("Put Back") { model.restore([entry]) }
                        .controlSize(.small)
                        .quietButton()
                } else {
                    Text("Deleted").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contextMenu {
            if inTrash { Button("Show in Trash") { model.revealInFinder(entry.trashedPath) } }
            Button("Copy Original Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.originalPath, forType: .string)
            }
        }
    }
}

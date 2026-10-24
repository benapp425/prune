import PruneCore
import SwiftUI

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    @State private var collapsed: Set<String> = []
    @AppStorage(Prefs.largeMinimumMB) private var largeMinimumMB = 250
    @AppStorage(Prefs.unusedMonths) private var unusedMonths = 6

    var body: some View {
        let result = model.result(for: category)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                header(result)
                    .padding(.bottom, 18)
                if let result {
                    if result.items.isEmpty {
                        empty
                    } else {
                        ForEach(result.sections, id: \.self) { section in
                            sectionView(section, items: result.items(in: section))
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(category == .duplicates ? "Comparing Files… \(Int((model.duplicateProgress ?? 0) * 100))%" : "Checking…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 100)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(category.title)
    }

    // MARK: Header

    private func header(_ result: CategoryResult?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: category.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 50, height: 50)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title).font(.system(size: 24, weight: .semibold))
                    Text(category.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if let result {
                    VStack(alignment: .trailing, spacing: 2) {
                        let p = Bytes.parts(result.reclaimable)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(p.number).font(.system(size: 30, weight: .light)).monospacedDigit()
                                .contentTransition(.numericText())
                            Text(p.unit).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(result.reclaimable > 0 ? Theme.accent : .secondary)
                        Caps("Total")
                    }
                }
            }
            if let result, !result.items.isEmpty {
                actions(result)
            }
        }
    }

    @ViewBuilder
    private func actions(_ result: CategoryResult) -> some View {
        HStack(spacing: 8) {
            if category == .duplicates {
                Button("Select Newer Copies") { selectExtraCopies(result) }
                    .help("Selects every copy except the oldest one of each file.")
            } else if result.recommendedBytes > 0 {
                Button("Select Recommended") {
                    model.addToTray(result.items.filter(\.recommended))
                }
            }
            if category != .duplicates {
                Button("Select All") { model.addToTray(result.items) }
            }
            let selected = result.items.filter { model.inTray($0.path) }
            if !selected.isEmpty {
                Button("Deselect All") { model.removeFromTray(selected.map(\.path)) }
            }
            Spacer()
            if category == .largeOld {
                Picker("Larger than", selection: $largeMinimumMB) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                .fixedSize()
                Picker("Not opened in", selection: $unusedMonths) {
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("2 years").tag(24)
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
        .onChange(of: largeMinimumMB) { model.analyze(includeDuplicates: false) }
        .onChange(of: unusedMonths) { model.analyze(includeDuplicates: false) }
    }

    private func selectExtraCopies(_ result: CategoryResult) {
        var seen = Set<Int>()
        var extras: [CleanupItem] = []
        for item in result.items {   // each group is sorted oldest first
            guard let g = item.group else { continue }
            if seen.insert(g).inserted { continue }
            extras.append(item)
        }
        model.addToTray(extras)
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: String, items: [CleanupItem]) -> some View {
        let isCollapsed = collapsed.contains(section)
        let total = category == .duplicates ? (items.first?.group).flatMap { model.duplicates?.groupGains[$0] } ?? 0
            : items.reduce(0) { $0 + $1.bytes }
        Button {
            withAnimation(.snappy) {
                if isCollapsed { collapsed.remove(section) } else { collapsed.insert(section) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.tertiary)
                Text(section).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text("\(items.count)").font(Theme.number(11)).foregroundStyle(.tertiary)
                Spacer()
                SizeText(bytes: total, font: Theme.number(11)).foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if !isCollapsed {
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(500).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 74) }
                    CleanupRow(item: item)
                }
                if items.count > 500 {
                    Text("\(items.count - 500) more items aren't shown. Select All includes them.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Items Found").font(.system(size: 15, weight: .medium))
            Text(emptyDetail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(.top, 50)
        .frame(maxWidth: .infinity)
    }

    private var emptyDetail: String {
        switch category {
        case .largeOld: "There are no files larger than \(Bytes.format(Int64(largeMinimumMB) * 1_000_000)) that you haven't opened in that time."
        case .duplicates: "There are no identical copies of files larger than 1 MB in your folders."
        case .developer: "There are no project dependencies or build files to remove."
        default: "There's nothing to remove here."
        }
    }
}

struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem
    @State private var hover = false

    var body: some View {
        let selected = model.inTray(item.path)
        let covered = !selected && model.trayCovering(item.path) != nil
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { selected || covered }, set: { _ in model.toggleTray(item) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(covered)
            FileIcon(path: item.path, isDirectory: item.isDirectory, iconPath: item.iconPath, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if item.recommended {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 10.5)).foregroundStyle(Theme.accent)
                            .help("Recommended")
                    }
                }
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = item.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if hover {
                Button {
                    model.revealInFinder(item.path)
                } label: {
                    Image(systemName: "magnifyingglass.circle").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
                .transition(.opacity)
            }
            if item.confidence != .review { ConfidencePill(confidence: item.confidence) }
            if let date = item.date, let label = item.dateLabel {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(date.relative).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(width: 96, alignment: .trailing)
            }
            SizeText(bytes: item.bytes, font: Theme.number(13))
                .foregroundStyle(selected || covered ? Theme.accent : .primary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hover ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if !covered { model.toggleTray(item) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            Button(selected ? "Deselect" : "Select") { model.toggleTray(item) }.disabled(covered)
            Button("Show in Finder") { model.revealInFinder(item.path) }
            Button("Show in File Browser") { model.reveal(inBrowse: item.path) }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }
}

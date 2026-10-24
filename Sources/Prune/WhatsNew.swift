import PruneCore
import SwiftUI

/// Reads CHANGELOG.md from the app bundle.
enum Changelog {
    static let repositoryURL = URL(string: "https://github.com/benapp425/prune")!

    struct Release: Identifiable {
        let version: String
        let date: String
        let notes: [String]
        var id: String { version }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Sections look like "## 1.1.0 — 2026-10-24" followed by "- " bullets.
    static func releases() -> [Release] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Release] = []
        var version = "", date = "", notes: [String] = []
        func flush() { if !version.isEmpty { out.append(Release(version: version, date: date, notes: notes)) } }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                let title = line.dropFirst(3)
                let parts = title.components(separatedBy: " — ")
                version = parts[0].trimmingCharacters(in: .whitespaces)
                date = parts.count > 1 ? parts[1] : ""
                notes = []
            } else if line.hasPrefix("- ") {
                notes.append(String(line.dropFirst(2)))
            } else if !line.isEmpty, !notes.isEmpty, !line.hasPrefix("#") {
                notes[notes.count - 1] += " " + line
            }
        }
        flush()
        return out
    }
}

struct WhatsNewView: View {
    @Environment(AppModel.self) private var model
    private let releases = Changelog.releases()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text("What's New in Prune").font(.system(size: 20, weight: .semibold))
                Text("Version \(Changelog.currentVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 26)
            .padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(releases.prefix(4)) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(release.version).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(release.date).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -2)
                                    Text(LocalizedStringKey(note))
                                        .font(.system(size: 12.5))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if releases.isEmpty {
                        Text("Release notes aren't available.").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .frame(height: 300)
            Divider()
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(Changelog.repositoryURL.appendingPathComponent("releases")) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue") { model.showWhatsNew = false }
                    .prominentButton()
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
    }
}

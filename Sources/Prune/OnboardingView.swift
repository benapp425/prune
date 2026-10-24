import PruneCore
import SwiftUI

/// First-run sheet: pick a color scheme, then allow Full Disk Access (watched until it's turned on).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Int
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(startAt page: Int = 0) { _page = State(initialValue: page) }

    var body: some View {
        VStack(spacing: 0) {
            if page == 0 { appearance } else { access }
        }
        .frame(width: 520)
        .animation(.snappy, value: page)
        .onReceive(timer) { _ in
            guard page == 1 else { return }
            let granted = Permissions.hasFullDiskAccess()
            if granted != model.hasFullDiskAccess { withAnimation(.snappy) { model.hasFullDiskAccess = granted } }
        }
    }

    // MARK: Page 1

    private var appearance: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                Text("Welcome to Prune").font(.system(size: 22, weight: .semibold))
                Text("Choose a color scheme. You can change it later in Settings.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)

            ThemePicker()
                .padding(.horizontal, 30)
                .padding(.top, 20)

            Picker("Appearance", selection: Binding(get: { ThemeStore.shared.appearance },
                                                    set: { ThemeStore.shared.appearance = $0 })) {
                ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.top, 16)

            HStack {
                Spacer()
                Button("Continue") { page = model.hasFullDiskAccess ? 2 : 1; if page == 2 { finish() } }
                    .prominentButton()
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
    }

    // MARK: Page 2

    private var access: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 56)
                Text("Allow Full Disk Access").font(.system(size: 20, weight: .semibold))
                Text("Prune needs Full Disk Access to measure every file on your Mac. Without it, Mail, Messages, the Trash and other apps' data aren't included, and macOS asks for permission one folder at a time.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)

            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1, text: "Open System Settings > Privacy & Security > Full Disk Access.")
                Step(number: 2, text: "Turn on Prune. If it isn't in the list, click the Add button (+) and choose Prune.")
                Step(number: 3, text: "Return to Prune. If macOS asks, click Quit & Reopen.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .padding(.horizontal, 30)
            .padding(.top, 22)

            HStack(spacing: 8) {
                Image(systemName: model.hasFullDiskAccess ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.hasFullDiskAccess ? Color(nsColor: .systemGreen) : .secondary)
                Text(model.hasFullDiskAccess ? "Full Disk Access is on." : "Waiting for Full Disk Access…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            HStack {
                if !model.hasFullDiskAccess {
                    Button("Scan Without Access") { finish() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.hasFullDiskAccess {
                    Button("Start Scan") { finish() }
                        .prominentButton()
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") { model.openPrivacySettings() }
                        .prominentButton()
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
    }

    private func finish() {
        if model.tree == nil { model.startScan() } else {
            UserDefaults.standard.set(true, forKey: Prefs.onboarded)
            model.showOnboarding = false
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(Theme.number(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.12), in: Circle())
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

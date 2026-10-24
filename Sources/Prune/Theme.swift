import AppKit
import Observation
import PruneCore
import SwiftUI
import UniformTypeIdentifiers

/// The color schemes offered at first launch and in Settings.
enum AppTheme: String, CaseIterable, Identifiable {
    case automatic, blue, indigo, teal, green, graphite, orange

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: "Automatic"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .teal: "Teal"
        case .green: "Green"
        case .graphite: "Graphite"
        case .orange: "Orange"
        }
    }

    var accent: Color {
        switch self {
        case .automatic: Color.accentColor
        case .blue: Self.adaptive(light: (0.04, 0.42, 0.95), dark: (0.25, 0.56, 1.0))
        case .indigo: Self.adaptive(light: (0.35, 0.34, 0.84), dark: (0.50, 0.49, 1.0))
        case .teal: Self.adaptive(light: (0.02, 0.53, 0.55), dark: (0.20, 0.72, 0.73))
        case .green: Self.adaptive(light: (0.12, 0.58, 0.32), dark: (0.24, 0.76, 0.44))
        case .graphite: Self.adaptive(light: (0.40, 0.41, 0.44), dark: (0.66, 0.67, 0.70))
        case .orange: Self.adaptive(light: (0.91, 0.36, 0.06), dark: (1.0, 0.50, 0.22))
        }
    }

    /// Graphite draws the storage breakdown in shades of gray; the others use a muted multicolor set.
    var monochrome: Bool { self == .graphite }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Holds the chosen theme. Observable, so every view that reads `Theme.accent` updates when it changes.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Theme.preferenceKey) }
    }

    var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }

    private init() {
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Theme.preferenceKey) ?? "") ?? .automatic
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Prune's look: quiet neutrals, one accent color for selection and anything you can remove, precise numerals.
@MainActor
enum Theme {
    static let preferenceKey = "theme"

    /// Views that read this re-render when the theme changes, because ThemeStore is observable.
    static var current: AppTheme { ThemeStore.shared.theme }

    static var accent: Color { current.accent }

    /// The tint applied to the whole window: nil for Automatic, so controls keep the system accent.
    static var windowTint: Color? { current == .automatic ? nil : current.accent }

    static let hairline = Color.primary.opacity(0.09)
    static let track = Color.primary.opacity(0.07)
    static let unseen = Color.primary.opacity(0.24)
    static let card = Color(nsColor: .controlBackgroundColor)

    static func color(for kind: UsageKind) -> Color { color(for: kind, theme: current) }

    static func color(for kind: UsageKind, theme: AppTheme) -> Color {
        if theme.monochrome {
            let shades: [UsageKind: Double] = [.apps: 0.30, .documents: 0.40, .media: 0.50, .downloads: 0.58,
                                               .appData: 0.36, .developer: 0.46, .system: 0.66, .other: 0.78]
            return Color(white: shades[kind] ?? 0.5)
        }
        switch kind {
        case .apps: return Color(red: 0.36, green: 0.55, blue: 0.93)
        case .documents: return Color(red: 0.29, green: 0.69, blue: 0.66)
        case .media: return Color(red: 0.62, green: 0.50, blue: 0.87)
        case .downloads: return Color(red: 0.91, green: 0.65, blue: 0.29)
        case .appData: return Color(red: 0.47, green: 0.55, blue: 0.65)
        case .developer: return Color(red: 0.43, green: 0.72, blue: 0.43)
        case .system: return Color(white: 0.56)
        case .other: return Color(white: 0.74)
        }
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// Small uppercase label with wide tracking, like the legends on hardware.
struct Caps: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// A rounded panel with a hairline edge.
struct Panel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// A thin capsule bar for proportions.
struct Meter: View {
    let fraction: Double
    var tint: Color = .secondary
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

struct ConfidencePill: View {
    let confidence: Confidence
    var body: some View {
        Text(confidence.label)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .fixedSize()
    }
    private var foreground: Color {
        switch confidence {
        case .safe, .rebuilds: Color(nsColor: .systemGreen)
        case .reinstall: Color(nsColor: .systemBlue)
        case .review: .secondary
        }
    }
    private var background: Color { foreground.opacity(confidence == .review ? 0.10 : 0.13) }
}

/// Size in bytes, with the number in monospaced digits.
struct SizeText: View {
    let bytes: Int64
    var font: Font = Theme.number(12.5)
    var body: some View {
        Text(Bytes.format(bytes)).font(font).monospacedDigit()
            .contentTransition(.numericText())
    }
}

/// Finder icons, cached.
@MainActor
enum Icons {
    private static var byPath: [String: NSImage] = [:]
    private static var byType: [String: NSImage] = [:]
    private static let folder = NSWorkspace.shared.icon(for: .folder)

    static func image(path: String, isDirectory: Bool, iconPath: String? = nil) -> NSImage {
        var source = iconPath ?? path
        // The demo's stand-in home folder doesn't exist; borrow the real folder's icon.
        if AppPaths.isDemo, source == AppPaths.home || source.hasPrefix(AppPaths.home + "/") {
            let real = NSHomeDirectory() + source.dropFirst(AppPaths.home.count)
            if FileManager.default.fileExists(atPath: real) { source = real }
        }
        let ext = (source as NSString).pathExtension.lowercased()
        let special = iconPath != nil || ext == "app" || ext == "photoslibrary" || ext == "movpkg"
            || specialFolders.contains(path)
        if special {
            if let cached = byPath[source] { return cached }
            if isDirectory && !FileManager.default.fileExists(atPath: source) && ext != "app" { return folder }
            let img = NSWorkspace.shared.icon(forFile: source)
            byPath[source] = img
            return img
        }
        if isDirectory { return ext.isEmpty || !Self.packageLike.contains(ext) ? folder : typeIcon(ext) }
        return typeIcon(ext)
    }

    private static func typeIcon(_ ext: String) -> NSImage {
        if let cached = byType[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let img = NSWorkspace.shared.icon(for: type)
        byType[ext] = img
        return img
    }

    private static let packageLike: Set<String> = ["bundle", "framework", "plugin", "pkg", "rtfd", "pages", "numbers",
                                                   "key", "sparsebundle", "xcarchive", "playground", "logicx"]

    private static let specialFolders: Set<String> = {
        let h = AppPaths.home
        let suffixes = ["", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music", "/Pictures", "/Library",
                        "/Applications", "/Public", "/.Trash"]
        return Set(suffixes.map { h + $0 } + suffixes.map { NSHomeDirectory() + $0 })
            .union(["/Applications", "/System", "/Library", "/Users"])
    }()
}

struct FileIcon: View {
    let path: String
    let isDirectory: Bool
    var iconPath: String? = nil
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: Icons.image(path: path, isDirectory: isDirectory, iconPath: iconPath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Date {
    /// "3 months ago", "yesterday".
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        if abs(timeIntervalSinceNow) < 60 { return "just now" }
        return f.localizedString(for: self, relativeTo: Date())
    }
}

enum Haptics {
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}

enum Sounds {
    static func trash() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}

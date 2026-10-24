import PruneCore
import SwiftUI

/// Swatches for each color scheme, each drawn as a small storage ring.
struct ThemePicker: View {
    @Bindable private var store = ThemeStore.shared
    var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                Swatch(theme: theme, selected: store.theme == theme)
                    .onTapGesture { withAnimation(.snappy) { store.theme = theme } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(theme.name)
            }
        }
    }
}

private struct Swatch: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 7)
                ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                    Circle()
                        .trim(from: arc.0, to: arc.1)
                        .stroke(arc.2, style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0.0, to: 0.18)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90 + 0.62 * 360))
                    .padding(9)
            }
            .frame(width: 46, height: 46)
            .padding(.top, 4)
            Text(theme.name)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(selected ? theme.accent.opacity(0.10) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var arcs: [(Double, Double, Color)] {
        let kinds: [(UsageKind, Double)] = [(.apps, 0.16), (.documents, 0.10), (.media, 0.12), (.appData, 0.18), (.system, 0.10)]
        var out: [(Double, Double, Color)] = []
        var cursor = 0.0
        for (kind, f) in kinds {
            out.append((cursor, cursor + f - 0.008, Theme.color(for: kind, theme: theme)))
            cursor += f
        }
        return out
    }
}

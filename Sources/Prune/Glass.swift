import SwiftUI

// Liquid Glass when built with the macOS 26 SDK (Swift 6.2 or later); frosted material otherwise.

extension View {
    /// A floating capsule surface, like the tray bar.
    @ViewBuilder
    func floatingSurface() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            materialCapsule()
        }
        #else
        materialCapsule()
        #endif
    }

    private func materialCapsule() -> some View {
        self
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    /// The prominent action style: glass on macOS 26, a filled button before.
    @ViewBuilder
    func prominentButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    @ViewBuilder
    func quietButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}

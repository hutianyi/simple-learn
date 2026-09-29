import SwiftUI
import UIKit

enum AppPalette {
    static let background = dynamic(light: 0xF5F6FA, dark: 0x101116)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1D24)
    static let textPrimary = dynamic(light: 0x16171C, dark: 0xF5F5F7)
    static let textSecondary = dynamic(light: 0x666A75, dark: 0xA7AAB4)
    static let accent = dynamic(light: 0x3758D4, dark: 0x8398FF)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct LargePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(AppPalette.accent)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct LargeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(AppPalette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(AppPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppPalette.textSecondary.opacity(0.22), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

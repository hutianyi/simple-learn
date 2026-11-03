import SwiftUI
import UIKit

public enum StudyTheme: CaseIterable {
    case ji, suan, lian, mo, ting, bei

    private var colors: (light: UInt32, dark: UInt32) {
        switch self {
        case .ji: (0x3758D4, 0x99B0FF)
        case .suan: (0x237A4B, 0x78D5A3)
        case .lian: (0xB55A1F, 0xFFBC89)
        case .mo: (0x8052B8, 0xC6A1EF)
        case .ting: (0x177C80, 0x79D0D5)
        case .bei: (0x5654B8, 0xABA8F5)
        }
    }

    public var accent: Color {
        let palette = colors
        return Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let hex = dark ? palette.dark : palette.light
            let channels = [16, 8, 0].map { Double((hex >> $0) & 0xFF) / 255 }
            let adjusted = channels.map { value in
                traits.accessibilityContrast == .high ? (dark ? value + (1 - value) * 0.15 : value * 0.8) : value
            }
            return UIColor(red: adjusted[0], green: adjusted[1], blue: adjusted[2], alpha: 1)
        })
    }

    public var buttonForeground: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 20 / 255.0, green: 22 / 255.0, blue: 28 / 255.0, alpha: 1)
                : .white
        })
    }
}

private struct StudyThemeKey: EnvironmentKey {
    static let defaultValue = StudyTheme.ji
}

public extension EnvironmentValues {
    var studyTheme: StudyTheme {
        get { self[StudyThemeKey.self] }
        set { self[StudyThemeKey.self] = newValue }
    }
}

public enum StudyAppearance {
    public static let pagePadding: CGFloat = 24
    public static let contentWidth: CGFloat = 760
    public static let sectionTitle = Font.system(.title3, design: .rounded, weight: .semibold)
    public static let moduleTitle = Font.system(.title2, design: .rounded, weight: .semibold)
    public static let moduleCornerRadius: CGFloat = 20
    public static let title = Font.system(.largeTitle, design: .rounded, weight: .bold)
    public static let background = Color(uiColor: .systemGroupedBackground)
    public static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

public struct StudyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.studyTheme) private var theme
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62)
            .foregroundStyle(theme.buttonForeground)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.82 : 1))
    }
}

public struct StudySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62)
            .foregroundStyle(.primary)
            .background(StudyAppearance.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.secondary.opacity(0.22)))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.82 : 1))
    }
}

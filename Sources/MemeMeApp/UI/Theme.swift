import SwiftUI

/// Colors and metrics of the dark panel (DESIGN.md › The panel).
enum Theme {
    /// 16 + the 120 pt mirror + 16 + 6 tiles of 88 pt 8 pt apart + 16.
    static let panelWidth: CGFloat = 736

    static let background: Color = rgb(0x1E1F24)
    static let surface: Color = rgb(0x26282E)
    static let border: Color = rgb(0x3A3C44)
    static let text: Color = rgb(0xECECEF)
    static let mutedText: Color = rgb(0xA9ACB5)
    static let accent: Color = rgb(0x7AA2FF)
    static let amber: Color = rgb(0xF5C451)
    static let green: Color = rgb(0x5FD38D)

    /// Every row of tiles is 6 wide: your memes (one row), the classic memes and the GIFs.
    static let columns: Int = 6
    static let rows: Int = 1
    static var resultLimit: Int { columns * rows }

    // Secondary tones used by the panel, popover and HUD.
    static let separator: Color = rgb(0x2E3037)
    static let chipBorder: Color = rgb(0x45474F)
    static let keycapBorder: Color = rgb(0x5A5D66)
    static let softText: Color = rgb(0xC9CCD4)
    static let placeholderText: Color = rgb(0x9A9DA6)
    static let link: Color = rgb(0x9DB8FF)
    static let onAccent: Color = rgb(0x0E1324)
    static let onGreen: Color = rgb(0x10241A)
    static let mirrorBackground: Color = rgb(0x0E0F12)
    static let warning: Color = rgb(0xFF8A80)
    static let badgeBackground: Color = rgb(0x0E0F12, opacity: 0.72)
    static let hudBackground: Color = rgb(0x1E1F24, opacity: 0.96)
    static let checkerLight: Color = rgb(0x2C2E34)
    static let checkerDark: Color = rgb(0x222328)

    private static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        let redComponent = Double((hex >> 16) & 0xFF) / 255
        let greenComponent = Double((hex >> 8) & 0xFF) / 255
        let blueComponent = Double(hex & 0xFF) / 255
        return Color(.sRGB, red: redComponent, green: greenComponent, blue: blueComponent, opacity: opacity)
    }
}

// MARK: - Shared panel controls

/// Small outlined capsule ("Clear", "Keep it", "More like this", "+ your face ×").
struct PanelCapsuleButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 12
    var foreground: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize))
            .foregroundColor(foreground)
            .lineLimit(1)
            .padding(.horizontal, fontSize < 12 ? 8 : 10)
            .padding(.vertical, fontSize < 12 ? 3 : 4)
            .background(
                Capsule().fill(configuration.isPressed ? Theme.surface : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(Theme.chipBorder, lineWidth: 1)
            )
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// Accent-filled primary button ("Find my memes", "Yes, group them").
struct PanelFilledButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 13
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(Theme.onAccent)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, fontSize < 13 ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .fixedSize()
    }
}

/// Text-only link button ("Undo", "Not now", "Keep as photo only").
struct PanelLinkButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 12
    var color: Color = Theme.link

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize))
            .foregroundColor(color.opacity(configuration.isPressed ? 0.7 : 1))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .fixedSize()
    }
}

/// ⌃ ⌘ M keycaps.
struct KeycapRow: View {
    var keys: [String] = ["⌃", "⌘", "M"]
    var color: Color = Theme.mutedText
    var fontSize: CGFloat = 11
    /// Filled caps with brighter text (used on the setup card).
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(filled ? Theme.text : color)
                    .padding(.horizontal, filled ? 6 : 5)
                    .padding(.vertical, filled ? 2 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: filled ? 5 : 4, style: .continuous)
                            .fill(filled ? Theme.background : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: filled ? 5 : 4, style: .continuous)
                            .strokeBorder(filled ? Theme.keycapBorder : color, lineWidth: 1)
                    )
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Control Command M")
    }
}

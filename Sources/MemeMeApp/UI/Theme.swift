import SwiftUI

/// Notch Black (docs/DESIGN.md › Design system): the drawer's colors and metrics. One black surface that matches the
/// notch, one signal color for "this one" and "done", the Mac's own type.
enum Theme {
    /// The panel: a search field over the grid, islands along its bottom (floating under the menu bar).
    static let panelWidth: CGFloat = 760
    static let panelRadius: CGFloat = 16
    static let searchBarHeight: CGFloat = 56
    static let bottomBarHeight: CGFloat = 62
    /// The grid's area (and the camera's column beside it): two rows and a peek at the third.
    static let contentHeight: CGFloat = 384
    /// The camera's column, 16 in from the panel's edge.
    static let faceColumnWidth: CGFloat = 212
    static let faceMirrorSize: CGFloat = 168
    /// The grid's side padding and spacing.
    static let gridPadding: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let gridRowSpacing: CGFloat = 14
    /// The HUD's drawer still hangs from the notch: its shoulders and bottom corners.
    static let shoulder: CGFloat = 12
    static let panelCornerRadius: CGFloat = 24
    /// The face editor's drawing of your face (200 points: one point per unit of `FaceSketch`).
    static let editorFaceSize: CGFloat = 200

    // MARK: Notch Black

    /// Every panel: the same black as the notch.
    static let ground: Color = rgb(0x000000)
    /// Fields and empty tiles.
    static let raised: Color = rgb(0x1C1C1E)
    /// Tokens, the active tab, hairlines.
    static let raised2: Color = rgb(0x2C2C2E)
    /// Keycaps, outlines, dashed wells.
    static let line: Color = rgb(0x3A3A3C)
    static let text: Color = rgb(0xF5F5F7)
    /// Everything else: 6.4:1 on black.
    static let text2: Color = rgb(0x8E8E93)
    /// This one, or done (the focus ring, the ↩ chip, the Copied check). Nothing else.
    static let signal: Color = rgb(0xFF9A5C)
    /// The panel's surface: a hair lighter than the notch, so it reads as a window.
    static let panelBackground: Color = rgb(0x161618)
    /// Menus over the panel (sources, actions).
    static let menuBackground: Color = rgb(0x1F1F21)
    /// Hairlines and the panel's edge.
    static let hairline: Color = Color.white.opacity(0.08)
    /// A tile before its picture loads.
    static let tileBackground: Color = rgb(0x1F1F22)
    /// A result's name under its tile, unless it is the focused one.
    static let softTitle: Color = rgb(0xAEAEB2)
    /// A tile's resting edge.
    static let tileEdge: Color = Color.white.opacity(0.06)

    // MARK: The names the views use, on Notch Black

    static let background: Color = ground
    static let surface: Color = raised
    static let border: Color = line
    static let mutedText: Color = text2
    static let accent: Color = signal
    /// Was a second highlight; Notch Black keeps one, so it is plain text white.
    static let amber: Color = text
    /// "Done" is the signal color too.
    static let green: Color = signal

    /// Tiles per row; 4 beside the camera's column.
    static let columns: Int = 5
    static let faceColumns: Int = 4
    /// Your things shown at most for a search: six rows.
    static let resultLimit: Int = 30

    // Secondary tones used by the panel, popover and HUD.
    static let separator: Color = raised2
    static let chipBorder: Color = line
    static let keycapBorder: Color = line
    static let softText: Color = text2
    static let placeholderText: Color = text2
    static let link: Color = text
    static let onAccent: Color = ground
    static let onGreen: Color = ground
    static let mirrorBackground: Color = raised
    static let warning: Color = rgb(0xFF8A80)
    static let badgeBackground: Color = rgb(0x000000, opacity: 0.62)
    static let hudBackground: Color = ground
    static let checkerLight: Color = raised2
    static let checkerDark: Color = raised

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

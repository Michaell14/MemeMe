import AppKit
import SwiftUI

/// The drawer's outline: its top edge flush with the top of the screen and flaring into it at both ends (inverted
/// `shoulder` corners), straight sides `shoulder` in from the window's edges, and round `cornerRadius` bottom corners.
/// The panel and the copied notice (HUD) both hang from the notch in this shape.
struct DrawerShape: Shape {
    var shoulder: CGFloat = Theme.shoulder
    var cornerRadius: CGFloat = Theme.panelCornerRadius

    func path(in rect: CGRect) -> Path {
        let inset = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let radius = max(0, min(cornerRadius, rect.height - inset, (rect.width - 2 * inset) / 2))
        // A quarter circle as one cubic curve.
        let handle: CGFloat = 0.5523 * inset
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right shoulder: from the top edge down into the right side, curving away from the drawer.
        path.addCurve(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
                      control1: CGPoint(x: rect.maxX - handle, y: rect.minY),
                      control2: CGPoint(x: rect.maxX - inset, y: rect.minY + inset - handle))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - inset, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + inset, y: rect.maxY),
                    radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX + inset, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + inset, y: rect.minY + inset),
                    radius: radius)
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        // Left shoulder, back up into the top edge.
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                      control1: CGPoint(x: rect.minX + inset, y: rect.minY + inset - handle),
                      control2: CGPoint(x: rect.minX + handle, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Where the drawer hangs on its screen: the menu bar's height, which is the height of the drawer's top band (the
/// "ears" either side of the notch), and the width of the camera housing in the middle of it (0 on a screen
/// without one, where the ears meet).
@MainActor final class NotchMetrics: ObservableObject {
    @Published private(set) var bandHeight: CGFloat = 32
    @Published private(set) var notchWidth: CGFloat = 0

    func update(for screen: NSScreen?) {
        let measured = NotchMetrics.measure(screen)
        if bandHeight != measured.band { bandHeight = measured.band }
        if notchWidth != measured.notch { notchWidth = measured.notch }
    }

    /// The menu bar's height on `screen` (the notch's height on a Mac with one; the system's menu bar thickness
    /// while it is hidden) and the notch's width.
    static func measure(_ screen: NSScreen?) -> (band: CGFloat, notch: CGFloat) {
        guard let screen else { return (band: 32, notch: 0) }
        var band = screen.safeAreaInsets.top
        if band <= 0 {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            band = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
        }
        band = min(max(band, 24), 44).rounded()
        var notch: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = max(0, screen.frame.width - left.width - right.width)
        }
        return (band: band, notch: notch.rounded(.up))
    }
}

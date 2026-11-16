import AppKit
import SwiftUI

/// Frosted glass (docs/DESIGN.md › Design system): the panel, its islands and its menus blur what is behind them,
/// under a dark tint, edged in light. The panel blurs the desktop (behind the window); islands and menus blur the
/// panel's own content (within the window).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // The panel never activates MemeMe: keep the blur live anyway.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != blending { view.blendingMode = blending }
    }
}

/// A glass surface's fill and edge: the blur, a tint over it, a 1 px white edge and a brighter line along the top.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var blending: NSVisualEffectView.BlendingMode = .withinWindow
    /// Over the blur: the panel's dark tint, or an island's light film.
    var tint: Color = Theme.glassTint
    var edge: Color = Theme.glassEdge
    var shadow = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blending: blending)
                    tint
                }
                .clipShape(shape)
            )
            .overlay(shape.strokeBorder(edge, lineWidth: 1).allowsHitTesting(false))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Theme.glassHighlight, .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(shadow ? 0.25 : 0), radius: 12, x: 0, y: 8)
    }
}

extension View {
    /// A glass surface (see `GlassSurface`).
    func glass(cornerRadius: CGFloat, blending: NSVisualEffectView.BlendingMode = .withinWindow,
               tint: Color = Theme.glassTint, edge: Color = Theme.glassEdge, shadow: Bool = true) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, blending: blending, tint: tint, edge: edge, shadow: shadow))
    }
}

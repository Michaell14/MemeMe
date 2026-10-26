import AppKit
import AVFoundation
import CoreMedia
import MemeMeCore
import QuartzCore
import SwiftUI

/// Observes `session.isRunning` from a nonisolated context, so the KVO callback is never
/// treated as main-actor code; `onChange` runs on whatever thread AVFoundation reports from.
private func observePreviewSessionRunning(
    _ session: AVCaptureSession,
    onChange: @escaping @Sendable (Bool) -> Void
) -> NSKeyValueObservation {
    session.observe(\.isRunning, options: [.initial, .new]) { observed, _ in
        onChange(observed.isRunning)
    }
}

/// The live, mirrored camera preview with clickable eyes / mouth overlays.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var regionRects: [FaceRegion: CGRect]   // Vision-normalized image coordinates
    var pins: Set<FaceRegion>
    var onToggle: (FaceRegion) -> Void      // only .eyes and .mouth are clickable

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView(session: session)
        view.onToggle = onToggle
        view.update(regionRects: regionRects, pins: pins)
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.attach(session)
        nsView.onToggle = onToggle
        nsView.update(regionRects: regionRects, pins: pins)
    }
}

extension CameraPreviewView {
    /// Layer-backed, non-flipped view. Its bounds, its sublayers and Vision-normalized rects all
    /// use a bottom-left origin, so overlay drawing and click hit-testing share one mapping.
    final class PreviewHostView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer
        var onToggle: ((FaceRegion) -> Void)?

        private var regionRects: [FaceRegion: CGRect] = [:]
        private var pins: Set<FaceRegion> = []
        private var isPointerInside = false
        private var overlays: [FaceRegion: CAShapeLayer] = [:]
        private var runningObservation: NSKeyValueObservation?

        private static let clickableRegions: [FaceRegion] = [.eyes, .mouth]
        /// Smallest on-screen size of a region, so thin eye rects stay easy to click.
        private static let minimumTargetSize = CGSize(width: 24, height: 16)
        /// Used until the camera reports its format (the session preset is 640×480).
        private static let fallbackVideoSize = CGSize(width: 640, height: 480)
        private static let pinnedFill = CGColor(red: 245.0 / 255.0, green: 196.0 / 255.0, blue: 81.0 / 255.0, alpha: 0.45)
        private static let pinnedStroke = CGColor(red: 245.0 / 255.0, green: 196.0 / 255.0, blue: 81.0 / 255.0, alpha: 0.9)
        private static let hoverStroke = CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        private static let backdrop = CGColor(red: 38.0 / 255.0, green: 40.0 / 255.0, blue: 46.0 / 255.0, alpha: 1)

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill

            for region in PreviewHostView.clickableRegions {
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.strokeColor = nil
                shape.lineWidth = 1.5
                shape.isHidden = true
                overlays[region] = shape
            }

            installLayersIfNeeded()
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
            watchRunningState(of: session)
        }

        required init?(coder: NSCoder) {
            return nil
        }

        override var isFlipped: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // MARK: Inputs

        func attach(_ session: AVCaptureSession) {
            guard previewLayer.session !== session else { return }
            previewLayer.session = session
            watchRunningState(of: session)
        }

        func update(regionRects: [FaceRegion: CGRect], pins: Set<FaceRegion>) {
            guard regionRects != self.regionRects || pins != self.pins else { return }
            self.regionRects = regionRects
            self.pins = pins
            updateOverlays()
        }

        // MARK: Layout

        override func layout() {
            super.layout()
            layoutLayers()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            layoutLayers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installLayersIfNeeded()
            updateContentsScale()
            applyMirroring()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateContentsScale()
        }

        // MARK: Mouse

        override func mouseEntered(with event: NSEvent) {
            isPointerInside = true
            updateOverlays()
        }

        override func mouseExited(with event: NSEvent) {
            isPointerInside = false
            updateOverlays()
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let clicked = hitRegion(at: point) else {
                super.mouseDown(with: event)
                return
            }
            onToggle?(clicked)
        }

        // MARK: Private

        private func installLayersIfNeeded() {
            guard let root = layer, previewLayer.superlayer == nil else { return }
            root.backgroundColor = PreviewHostView.backdrop
            root.masksToBounds = true
            previewLayer.frame = bounds
            root.addSublayer(previewLayer)
            for region in PreviewHostView.clickableRegions {
                if let shape = overlays[region] {
                    shape.frame = bounds
                    root.addSublayer(shape)
                }
            }
            updateContentsScale()
        }

        private func watchRunningState(of session: AVCaptureSession) {
            runningObservation = observePreviewSessionRunning(session) { [weak self] _ in
                let view = self
                Task { @MainActor in
                    view?.applyMirroring()
                }
            }
        }

        /// Mirrors the preview through its connection once the connection exists (after the session gets its input).
        private func applyMirroring() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            if !connection.isVideoMirrored {
                connection.isVideoMirrored = true
                updateOverlays()
            }
        }

        private func layoutLayers() {
            installLayersIfNeeded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            for shape in overlays.values {
                shape.frame = bounds
            }
            CATransaction.commit()
            updateOverlays()
        }

        private func updateContentsScale() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            for shape in overlays.values {
                shape.contentsScale = scale
            }
        }

        private func updateOverlays() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            for region in PreviewHostView.clickableRegions {
                guard let shape = overlays[region] else { continue }
                guard let rect = displayRect(for: region) else {
                    shape.isHidden = true
                    shape.path = nil
                    continue
                }
                if pins.contains(region) {
                    shape.fillColor = PreviewHostView.pinnedFill
                    shape.strokeColor = PreviewHostView.pinnedStroke
                    shape.lineWidth = 1
                    shape.lineDashPattern = nil
                    shape.isHidden = false
                } else if isPointerInside {
                    shape.fillColor = nil
                    shape.strokeColor = PreviewHostView.hoverStroke
                    shape.lineWidth = 1.5
                    shape.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 3)]
                    shape.isHidden = false
                } else {
                    shape.isHidden = true
                }
                let radius = min(6, rect.width / 2, rect.height / 2)
                shape.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
        }

        /// The region's rect in view coordinates, grown to the minimum click target size.
        private func displayRect(for region: FaceRegion) -> CGRect? {
            guard let normalized = regionRects[region] else { return nil }
            let mapped = viewRect(fromNormalized: normalized)
            guard !mapped.isNull,
                  mapped.origin.x.isFinite, mapped.origin.y.isFinite,
                  mapped.width.isFinite, mapped.height.isFinite else {
                return nil
            }
            let width = max(mapped.width, PreviewHostView.minimumTargetSize.width)
            let height = max(mapped.height, PreviewHostView.minimumTargetSize.height)
            return CGRect(x: mapped.midX - width / 2, y: mapped.midY - height / 2, width: width, height: height)
        }

        /// Aspect-fill + mirror mapping from Vision-normalized image coordinates (origin bottom-left,
        /// unmirrored camera frame) to this non-flipped view's coordinates.
        private func viewRect(fromNormalized rect: CGRect) -> CGRect {
            let area = bounds
            guard area.width > 0, area.height > 0 else { return .null }
            let video = videoSize()
            let scale = max(area.width / video.width, area.height / video.height)
            let shownWidth = video.width * scale
            let shownHeight = video.height * scale
            let originX = area.minX + (area.width - shownWidth) / 2
            let originY = area.minY + (area.height - shownHeight) / 2
            let isMirrored = previewLayer.connection?.isVideoMirrored ?? true
            let normalizedX = isMirrored ? 1 - rect.maxX : rect.minX
            return CGRect(
                x: originX + normalizedX * shownWidth,
                y: originY + rect.minY * shownHeight,
                width: rect.width * shownWidth,
                height: rect.height * shownHeight
            )
        }

        /// Pixel dimensions of the video shown in the preview.
        private func videoSize() -> CGSize {
            if let connection = previewLayer.connection {
                for port in connection.inputPorts where port.mediaType == .video {
                    if let description = port.formatDescription,
                       let size = PreviewHostView.dimensions(of: description) {
                        return size
                    }
                }
            }
            if let input = previewLayer.session?.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
               let size = PreviewHostView.dimensions(of: input.device.activeFormat.formatDescription) {
                return size
            }
            return PreviewHostView.fallbackVideoSize
        }

        private static func dimensions(of description: CMFormatDescription) -> CGSize? {
            let pixels = CMVideoFormatDescriptionGetDimensions(description)
            guard pixels.width > 0, pixels.height > 0 else { return nil }
            return CGSize(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
        }

        /// The clickable region under the point; the nearest center wins where enlarged targets overlap.
        private func hitRegion(at point: CGPoint) -> FaceRegion? {
            var best: (region: FaceRegion, distance: CGFloat)?
            for region in PreviewHostView.clickableRegions {
                guard let rect = displayRect(for: region), rect.contains(point) else { continue }
                let dx = point.x - rect.midX
                let dy = point.y - rect.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                if let current = best, current.distance <= distance { continue }
                best = (region: region, distance: distance)
            }
            return best?.region
        }
    }
}

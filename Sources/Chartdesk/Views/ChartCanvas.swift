import AppKit
import Combine
import SwiftUI

// MARK: - Zoom controller

/// Bridges the toolbar and menu commands to the AppKit scroll view that actually shows the chart.
final class ChartViewerController: ObservableObject {

    @Published private(set) var magnification: CGFloat = 1

    private weak var scrollView: NSScrollView?
    private let step: CGFloat = 1.3

    var zoomPercentText: String {
        let percent = Int((magnification * 100).rounded())
        return "\(max(percent, 1))%"
    }

    // MARK: Wiring

    func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        syncMagnification()
    }

    func detach(_ scrollView: NSScrollView) {
        if self.scrollView === scrollView {
            self.scrollView = nil
        }
    }

    func syncMagnification() {
        guard let scrollView = scrollView else { return }
        let value = scrollView.magnification
        if abs(value - magnification) > 0.0005 {
            magnification = value
        }
    }

    // MARK: Zoom

    func zoomIn() { setMagnification(magnification * step) }

    func zoomOut() { setMagnification(magnification / step) }

    func actualSize() { setMagnification(1) }

    func zoomToFit() {
        guard let scrollView = scrollView, let scale = fitScale() else { return }
        scrollView.magnification = clamp(scale, in: scrollView)
        centerDocument(verticallyCentered: true)
        magnification = scrollView.magnification
    }

    func applyInitialZoom(fit: Bool) {
        if fit {
            zoomToFit()
        } else {
            guard let scrollView = scrollView else { return }
            scrollView.magnification = clamp(1, in: scrollView)
            centerDocument(verticallyCentered: false)
            magnification = scrollView.magnification
        }
    }

    /// Double-click behaviour: swap between "whole chart" and "one pixel per point".
    func toggleFitAndActualSize() {
        guard let fit = fitScale() else { return }
        if abs(magnification - fit) < 0.01 {
            setMagnification(1)
        } else {
            zoomToFit()
        }
    }

    // MARK: Internals

    private func fitScale() -> CGFloat? {
        guard let scrollView = scrollView,
              let document = scrollView.documentView,
              document.frame.width > 1,
              document.frame.height > 1 else { return nil }

        let available = scrollView.contentView.frame.size
        let inset: CGFloat = 24
        let width = max(available.width - inset, 40)
        let height = max(available.height - inset, 40)
        return min(width / document.frame.width, height / document.frame.height)
    }

    private func clamp(_ value: CGFloat, in scrollView: NSScrollView) -> CGFloat {
        min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
    }

    /// Zooms about a point in the document, so the feature under the pointer stays under it.
    func zoom(by factor: CGFloat, at point: NSPoint) {
        guard let scrollView = scrollView, scrollView.documentView != nil,
              factor > 0, factor.isFinite else { return }
        scrollView.setMagnification(clamp(magnification * factor, in: scrollView),
                                    centeredAt: point)
        magnification = scrollView.magnification
    }

    /// Drags the plate under the pointer. `delta` is in screen points.
    func pan(by delta: NSSize) {
        guard let scrollView = scrollView, scrollView.documentView != nil else { return }
        let scale = max(scrollView.magnification, 0.0001)
        var origin = scrollView.contentView.bounds.origin
        origin.x -= delta.width / scale
        origin.y += delta.height / scale
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func setMagnification(_ target: CGFloat) {
        guard let scrollView = scrollView, scrollView.documentView != nil else { return }
        let visible = scrollView.documentVisibleRect
        let center = NSPoint(x: visible.midX, y: visible.midY)
        scrollView.setMagnification(clamp(target, in: scrollView), centeredAt: center)
        magnification = scrollView.magnification
    }

    private func centerDocument(verticallyCentered: Bool) {
        guard let scrollView = scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        let x = max(0, (document.frame.width - visible.width) / 2)
        let y = verticallyCentered ? max(0, (document.frame.height - visible.height) / 2) : 0
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - AppKit pieces

/// Keeps the chart centred when it is smaller than the window instead of pinning it to a corner.
final class CenteringClipView: NSClipView {

    /// The window is movable by its background, so every view over the plate has to say that
    /// a drag on it belongs to the chart rather than to the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }

        if rect.size.width > document.frame.size.width {
            rect.origin.x = (document.frame.size.width - rect.size.width) / 2
        }
        if rect.size.height > document.frame.size.height {
            rect.origin.y = (document.frame.size.height - rect.size.height) / 2
        }
        return rect
    }
}

/// Top-left origin, so a chart that is taller than the window opens at the top of the plate.
final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Transparent to the mouse. The plate is not interactive in itself — dragging it pans and
    /// double-clicking it toggles zoom, both of which belong to the document view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The scroll view's document: the plate, with the annotation layer pinned exactly on top of
/// it. Both are the size of the image in points, so a mark recorded at 30% across the chart
/// lands at 30% across at any zoom.
final class ChartDocumentView: NSView {

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    let imageView = FlippedImageView()
    let overlay = AnnotationOverlayView()

    init() {
        super.init(frame: .zero)

        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.isEditable = false
        imageView.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]

        addSubview(imageView)
        addSubview(overlay, positioned: .above, relativeTo: imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var onPan: ((NSSize) -> Void)?
    var onDoubleClick: (() -> Void)?

    private var panAnchor: NSPoint?

    override func mouseDown(with event: NSEvent) {
        // Handled here rather than with a click recogniser, which would have to delay every
        // drag to find out whether a second click was coming.
        if event.clickCount == 2 {
            panAnchor = nil
            onDoubleClick?()
            return
        }
        panAnchor = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = panAnchor else { return }
        let now = event.locationInWindow
        panAnchor = now
        onPan?(NSSize(width: now.x - anchor.x, height: now.y - anchor.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard panAnchor != nil else { return }
        panAnchor = nil
        NSCursor.pop()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func resize(to size: CGSize) {
        frame = NSRect(origin: .zero, size: size)
        imageView.frame = bounds
        overlay.frame = bounds
        overlay.needsDisplay = true
    }
}

/// A scroll view where the wheel zooms instead of scrolling; panning is a drag.
final class ChartScrollView: NSScrollView {

    override var mouseDownCanMoveWindow: Bool { false }

    var onScrollZoom: ((CGFloat, NSPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        // A trackpad reports many small precise deltas where a wheel reports a few large
        // ones, so each needs its own sensitivity to feel the same.
        let step = event.hasPreciseScrollingDeltas ? delta * 0.004 : delta * 0.06
        let point = documentView?.convert(event.locationInWindow, from: nil)
            ?? NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        onScrollZoom?(exp(step), point)
    }
}

// MARK: - Canvas

struct ChartCanvas: NSViewRepresentable {

    let image: NSImage?
    /// Changing this resets the zoom (new chart or new rotation); a night-mode swap does not.
    let resetKey: String
    let background: NSColor
    let fitOnOpen: Bool
    let controller: ChartViewerController

    let annotations: [Annotation]
    let chartKey: String
    let rotation: Int
    let isAnnotating: Bool
    let tool: AnnotationTool
    let color: AnnotationColor
    let width: AnnotationWidth
    let onDraw: (Annotation) -> Void
    let onErase: (UUID) -> Void

    // DEPRECATED (1.0): the taxi-routing pass-through, down to `onAlignZoom`.
    let preview: [[CGPoint]]
    let reference: [[CGPoint]]
    let isCalibrating: Bool
    let onCalibrationClick: (CGPoint) -> Void

    let isAligning: Bool
    let onAlignDrag: (CGPoint) -> Void
    let onAlignTurn: (Double, CGPoint) -> Void
    let onAlignZoom: (Double, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, fitOnOpen: fitOnOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ChartScrollView()

        let clipView = CenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = background
        scrollView.contentView = clipView

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.04
        scrollView.maxMagnification = 20
        scrollView.usesPredominantAxisScrolling = false

        let document = ChartDocumentView()
        scrollView.documentView = document

        // While annotate mode is on the overlay is the view under the pointer, so drawing wins
        // over panning without either needing to know about the other.
        document.onPan = { [weak controller] delta in controller?.pan(by: delta) }
        document.onDoubleClick = { [weak controller] in controller?.toggleFitAndActualSize() }
        scrollView.onScrollZoom = { [weak controller] factor, point in
            controller?.zoom(by: factor, at: point)
        }

        context.coordinator.configure(scrollView: scrollView, document: document)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.fitOnOpen = fitOnOpen
        if nsView.backgroundColor != background {
            nsView.backgroundColor = background
            (nsView.contentView as? CenteringClipView)?.backgroundColor = background
        }
        context.coordinator.apply(image: image, resetKey: resetKey)

        guard let overlay = (nsView.documentView as? ChartDocumentView)?.overlay else { return }
        overlay.chartKey = chartKey
        overlay.annotations = annotations
        overlay.rotation = rotation
        overlay.isActive = isAnnotating
        overlay.tool = tool
        overlay.color = color
        overlay.width = width
        overlay.onDraw = onDraw
        overlay.onErase = onErase
        overlay.preview = preview
        overlay.reference = reference
        overlay.isCalibrating = isCalibrating
        overlay.onCalibrationClick = onCalibrationClick
        overlay.isAligning = isAligning
        overlay.onAlignDrag = onAlignDrag
        overlay.onAlignTurn = onAlignTurn
        overlay.onAlignZoom = onAlignZoom
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown(scrollView: nsView)
    }

    final class Coordinator: NSObject {
        let controller: ChartViewerController
        var fitOnOpen: Bool

        private weak var scrollView: NSScrollView?
        private weak var document: ChartDocumentView?
        private var appliedImage: NSImage?
        private var currentResetKey = ""
        private var pendingFit = true
        private var magnifyObserver: NSObjectProtocol?

        init(controller: ChartViewerController, fitOnOpen: Bool) {
            self.controller = controller
            self.fitOnOpen = fitOnOpen
            super.init()
        }

        func configure(scrollView: NSScrollView, document: ChartDocumentView) {
            self.scrollView = scrollView
            self.document = document
            controller.attach(scrollView)

            magnifyObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.controller.syncMagnification()
            }
        }

        func teardown(scrollView: NSScrollView) {
            if let observer = magnifyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            magnifyObserver = nil
            controller.detach(scrollView)
        }

        func apply(image: NSImage?, resetKey: String) {
            guard let document = document else { return }

            if resetKey != currentResetKey {
                currentResetKey = resetKey
                pendingFit = true
                appliedImage = nil
                document.imageView.image = nil
                document.resize(to: .zero)
            }

            guard let image = image, image !== appliedImage else { return }

            appliedImage = image
            document.imageView.image = image
            document.resize(to: image.size)

            if pendingFit {
                pendingFit = false
                let shouldFit = fitOnOpen
                DispatchQueue.main.async { [weak self] in
                    self?.controller.applyInitialZoom(fit: shouldFit)
                }
            }
        }
    }
}

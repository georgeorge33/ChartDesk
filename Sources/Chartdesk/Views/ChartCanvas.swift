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
}

// MARK: - Canvas

struct ChartCanvas: NSViewRepresentable {

    let image: NSImage?
    /// Changing this resets the zoom (new chart or new rotation); a night-mode swap does not.
    let resetKey: String
    let background: NSColor
    let fitOnOpen: Bool
    let controller: ChartViewerController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, fitOnOpen: fitOnOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()

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

        let imageView = FlippedImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.isEditable = false
        imageView.frame = .zero
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        context.coordinator.configure(scrollView: scrollView, imageView: imageView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.fitOnOpen = fitOnOpen
        if nsView.backgroundColor != background {
            nsView.backgroundColor = background
            (nsView.contentView as? CenteringClipView)?.backgroundColor = background
        }
        context.coordinator.apply(image: image, resetKey: resetKey)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown(scrollView: nsView)
    }

    final class Coordinator: NSObject {
        let controller: ChartViewerController
        var fitOnOpen: Bool

        private weak var scrollView: NSScrollView?
        private weak var imageView: NSImageView?
        private var appliedImage: NSImage?
        private var currentResetKey = ""
        private var pendingFit = true
        private var magnifyObserver: NSObjectProtocol?

        init(controller: ChartViewerController, fitOnOpen: Bool) {
            self.controller = controller
            self.fitOnOpen = fitOnOpen
            super.init()
        }

        func configure(scrollView: NSScrollView, imageView: NSImageView) {
            self.scrollView = scrollView
            self.imageView = imageView
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
            guard let imageView = imageView else { return }

            if resetKey != currentResetKey {
                currentResetKey = resetKey
                pendingFit = true
                appliedImage = nil
                imageView.image = nil
                imageView.frame = .zero
            }

            guard let image = image, image !== appliedImage else { return }

            appliedImage = image
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)

            if pendingFit {
                pendingFit = false
                let shouldFit = fitOnOpen
                DispatchQueue.main.async { [weak self] in
                    self?.controller.applyInitialZoom(fit: shouldFit)
                }
            }
        }

        @objc func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
            controller.toggleFitAndActualSize()
        }
    }
}
